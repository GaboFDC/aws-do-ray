#!/bin/bash

source ./env_vars

# Function to get cloud deployment ID from cloud name
get_cloud_deployment_id() {
    local ANYSCALE_CLOUD_NAME=$1
    local CLOUD_INFO
    local DEPLOYMENT_ID

    CLOUD_INFO=$(anyscale cloud config get --name "$ANYSCALE_CLOUD_NAME")
    if [ $? -ne 0 ]; then
        echo "Error getting cloud configuration for $ANYSCALE_CLOUD_NAME"
        exit 1
    fi

    DEPLOYMENT_ID=$(echo "$CLOUD_INFO" | grep "^cloud_deployment_id: " | awk '{print $2}')
    if [ -z "$DEPLOYMENT_ID" ]; then
        echo "Could not find cloud deployment ID"
        exit 1
    fi

    echo "$DEPLOYMENT_ID"
}


echo "Getting cloud deployment ID for: $ANYSCALE_CLOUD_NAME"
CLOUD_DEPLOYMENT_ID=$(get_cloud_deployment_id "$ANYSCALE_CLOUD_NAME")
echo "Cloud Deployment ID: $CLOUD_DEPLOYMENT_ID"

# Deploy Anyscale operator
# custom-values.yaml disables the default eks.amazonaws.com/capacityType nodeSelector
# (which HyperPod blocks) and removes all capacityType-based nodeSelectors since
# HyperPod does not provide a capacity-type label on nodes by default.
echo "Installing/upgrading Anyscale operator..."
helm upgrade --install anyscale-operator anyscale/anyscale-operator \
    -f custom-values.yaml \
    --set-string global.cloudDeploymentId=${CLOUD_DEPLOYMENT_ID} \
    --set-string global.aws.region=${AWS_REGION} \
    --namespace anyscale \
    --wait

# The Helm chart does not support hostNetwork as a value, so we patch the deployment
# after Helm finishes. hostNetwork is required for the operator to communicate with
# the Anyscale control plane on HyperPod clusters.
# NOTE: This triggers a second rolling update of the operator pod.
echo "Patching operator deployment with hostNetwork: true..."
kubectl patch deployment anyscale-operator -n anyscale --patch "$(cat patch.yaml)"
echo "Waiting for operator rollout to complete..."
kubectl rollout status deployment/anyscale-operator -n anyscale --timeout=300s
