#!/bin/bash

CLUSTER_NAME=$1
ASG_GROUP_NAME=$2
S3_BUCKET=$3
KUBECONFIG_OBJECT=$4
REGION=$5

if [ -z "${CLUSTER_NAME}" ]; then
    echo "Cluster name is not specified."
    exit 1
fi

if [ -z "${ASG_GROUP_NAME}" ]; then
    echo "Autoscaling group name is not specified."
    exit 1
fi

if [ -z "${S3_BUCKET}" ]; then
    echo "S3 bucket name is not specified."
    exit 1
fi

if [ -z "${KUBECONFIG_OBJECT}" ]; then
    echo "Kubeconfig object name is not specified."
    exit 1
fi

if [ -z "${REGION}" ]; then
    echo "Region is not specified."
    exit 1
fi

if [ -z "$(sam --version)" ]; then
   echo "SAM not found, you need to install it first. Exiting ..."
    exit 1
fi

if [ -z "$(yq --version)" ]; then 
    echo "yq is not installed. Install yq first."
    exit 1
fi

git clone https://github.com/aws-samples/amazon-k8s-node-drainer.git
cd amazon-k8s-node-drainer

yq --yaml-output -i '.Parameters |= ({KubeConfigBucket: {Type: "String"}} + {KubeConfigObject: {Type: "String"}} + .)' template.yaml
yq --yaml-output -i '.Resources.DrainerFunction.Properties.Environment.Variables |= . + {"KUBE_CONFIG_BUCKET": {"Ref": "KubeConfigBucket"}, "KUBE_CONFIG_OBJECT": {"Ref": "KubeConfigObject"}}' template.yaml

sam build --use-container --skip-pull-image
sam package \
    --output-template-file packaged.yaml \
    --s3-bucket ${S3_BUCKET} \
    --region ${REGION}

sam deploy \
    --template-file packaged.yaml \
    --stack-name k8s-drainer \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides AutoScalingGroup=${ASG_GROUP_NAME} EksCluster=${CLUSTER_NAME} \
        KubeConfigBucket=${S3_BUCKET} KubeConfigObject=${KUBECONFIG_OBJECT} 