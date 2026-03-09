#!/bin/bash
# Getting variables
source ./env_vars

echo "Creating Anyscale namespace..."
kubectl create namespace ${NAMESPACE}

echo "Deploying Anyscale dependencies..."
pip install -U anyscale

anyscale login

helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update anyscale

# ==== Derive EKS cluster info from HyperPod ====
# Needed for both the AWS Load Balancer Controller and IRSA setup below.
echo "Deriving EKS cluster info from HyperPod cluster..."

EKS_CLUSTER_ARN=$(aws sagemaker describe-cluster \
    --cluster-name ${AWS_EKS_HYPERPOD_CLUSTER} \
    --region ${AWS_REGION} \
    --query 'Orchestrator.Eks.ClusterArn' \
    --output text)
EKS_CLUSTER_NAME=$(echo ${EKS_CLUSTER_ARN} | awk -F'/' '{print $NF}')

OIDC_URL=$(aws eks describe-cluster \
    --name ${EKS_CLUSTER_NAME} \
    --region ${AWS_REGION} \
    --query 'cluster.identity.oidc.issuer' \
    --output text)
OIDC_ID=$(echo ${OIDC_URL} | awk -F'/id/' '{print $2}')

ROLE_ARN=$(aws sagemaker describe-cluster \
    --cluster-name ${AWS_EKS_HYPERPOD_CLUSTER} \
    --region ${AWS_REGION} \
    --query 'InstanceGroups[0].ExecutionRole' \
    --output text)
ACCOUNT_ID=$(echo ${ROLE_ARN} | cut -d':' -f5)
ROLE_NAME=$(echo ${ROLE_ARN} | awk -F'/' '{print $NF}')

VPC_ID=$(aws eks describe-cluster \
    --name ${EKS_CLUSTER_NAME} \
    --region ${AWS_REGION} \
    --query 'cluster.resourcesVpcConfig.vpcId' \
    --output text)

echo "EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME}"
echo "VPC_ID=${VPC_ID}"
echo "ACCOUNT_ID=${ACCOUNT_ID}"

# ==== Install AWS Load Balancer Controller ====
# Required on HyperPod EKS because there is no in-tree cloud controller manager.
# The LBC manages NLB target registration using IP target mode, which is the only
# mode that works on HyperPod (instance mode fails because HyperPod nodes are not
# visible EC2 instances in the customer account).
# Reference: https://docs.anyscale.com/admin/cloud/create-eks-cloud (Step 4)
# HyperPod support: https://github.com/kubernetes-sigs/aws-load-balancer-controller/pull/3886

echo "Setting up AWS Load Balancer Controller..."

# 1. Create IAM policy for LBC (idempotent — ignores AlreadyExists error)
LBC_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
curl -so /tmp/iam_policy.json \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json
aws iam create-policy \
    --policy-name ${LBC_POLICY_NAME} \
    --policy-document file:///tmp/iam_policy.json 2>/dev/null || true

LBC_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${LBC_POLICY_NAME}"

# 2. Create IRSA for the LBC service account
eksctl create iamserviceaccount \
    --cluster=${EKS_CLUSTER_NAME} \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn=${LBC_POLICY_ARN} \
    --override-existing-serviceaccounts \
    --region ${AWS_REGION} \
    --approve

# 3. Tag public subnets for LBC subnet auto-discovery
# The LBC requires kubernetes.io/role/elb=1 on public subnets to know where
# to place internet-facing load balancers.
echo "Tagging public subnets for LBC discovery..."
aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=true" \
    --query 'Subnets[*].SubnetId' --output text --region ${AWS_REGION} | tr '\t' '\n' | \
    xargs -I{} aws ec2 create-tags --resources {} \
    --tags Key=kubernetes.io/role/elb,Value=1 --region ${AWS_REGION}

# 4. Install the LBC via Helm
# Version 1.11.0 matches Anyscale docs; includes HyperPod support (LBC v2.11+).
# --set region and --set vpcId are required on HyperPod because nodes lack standard
# EC2 instance metadata that the LBC normally uses for auto-detection.
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update eks
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
    --version 1.11.0 \
    --namespace kube-system \
    --set clusterName=${EKS_CLUSTER_NAME} \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region=${AWS_REGION} \
    --set vpcId=${VPC_ID} \
    --install

echo "Waiting for LBC to become ready..."
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s

# ==== Install ingress-nginx ====
# Uses LBC-managed NLB with IP target mode (required for HyperPod).
# - "external" tells the LBC to manage this NLB (replaces legacy "nlb" annotation)
# - "ip" registers pod IPs directly into target groups (HyperPod nodes are not
#   resolvable EC2 instances, so "instance" target type cannot work)
# Reference: https://docs.anyscale.com/admin/cloud/create-eks-cloud (Step 4)
echo "Installing ingress-nginx via Helm (LBC-managed NLB with IP targets)..."

helm repo add nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm upgrade ingress-nginx nginx/ingress-nginx \
    --version 4.12.1 \
    --namespace ingress-nginx \
    --create-namespace \
    --install \
    --set controller.service.type=LoadBalancer \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-cross-zone-load-balancing-enabled"="true" \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=external \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-nlb-target-type"=ip \
    --set controller.allowSnippetAnnotations=true \
    --set controller.config.enable-underscores-in-headers=true \
    --set controller.config.annotations-risk-level=Critical \
    --set controller.autoscaling.enabled=true


# ==== Node labeling for capacityType ====
# HyperPod nodes already have the "capacityType=ON_DEMAND" label natively.
# The Anyscale operator's default Helm patches reference "eks.amazonaws.com/capacityType",
# which HyperPod blocks at the API level. Instead of labeling nodes manually here,
# we override the operator's marketType patches in custom-values.yaml to use the
# HyperPod-native "capacityType" label. No manual node labeling needed.

# ==== Setup IRSA for Anyscale service account ====
# Anyscale pods need S3 access via IRSA. The HyperPod execution role's trust policy
# must allow AssumeRoleWithWebIdentity from the EKS OIDC provider.

echo "Configuring IRSA for Anyscale operator..."

# Variables EKS_CLUSTER_NAME, OIDC_ID, ROLE_ARN, ACCOUNT_ID, ROLE_NAME
# were already extracted above in the "Derive EKS cluster info" section.

OIDC_PROVIDER="oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"

cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "sagemaker.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    },
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:*"
        }
      }
    }
  ]
}
EOF

echo "Updating trust policy for role ${ROLE_NAME}..."
aws iam update-assume-role-policy \
    --role-name ${ROLE_NAME} \
    --policy-document file:///tmp/trust-policy.json

# Annotate Anyscale service account with the execution role for IRSA
echo "Annotating Anyscale service account with IAM role..."
kubectl annotate serviceaccount anyscale-operator -n ${NAMESPACE} \
    eks.amazonaws.com/role-arn=${ROLE_ARN} \
    --overwrite

rm -f /tmp/trust-policy.json
echo "IRSA setup complete."
