#!/bin/bash

set -xe

NAMESPACE=${1}
SQS_QUEUE_URL=${2}
CHART_VERSION=${3}
AWS_NODE_TERMINATION_HANDLER_ANN=${4}

required_args=(
    NAMESPACE
    SQS_QUEUE_URL
    CHART_VERSION
    AWS_NODE_TERMINATION_HANDLER_ANN
)

for arg in "${required_args[@]}"; do
    if [[ -z "${!arg}" ]]; then
        echo "ERROR: $arg is not set"
        exit 1
    fi
done

BASE_DIR=/home/ubuntu/aws-node-termination-handler
mkdir -p ${BASE_DIR}

cat <<EOF | tee ${BASE_DIR}/values.yaml
---
replicas: 1
enableSqsTerminationDraining: true
queueURL: ${SQS_QUEUE_URL}
serviceAccount.name: aws-node-termination-handler
serviceAccount.create: true
serviceAccount.annotations:
    ${AWS_NODE_TERMINATION_HANDLER_ANN}
awsRegion: us-east-1
workers: 5
useProviderId: true
EOF

# Login into ECR
aws ecr-public get-login-password \
     --region us-east-1 | helm registry login \
     --username AWS \
     --password-stdin public.ecr.aws

helm upgrade --install aws-node-termination-handler \
  --namespace ${NAMESPACE} \
  -f ${BASE_DIR}/values.yaml \
  oci://public.ecr.aws/aws-ec2/helm/aws-node-termination-handler \
  --version $CHART_VERSION # 0.22.0