#!/bin/bash

set -ex

NAMESPACE=${1}
ROLE_ANN=${2}

required_args=(
  NAMESPACE
  ROLE_ANN
)

for arg in "${required_args[@]}"; do
  if [[ -z "${!arg}" ]]; then
    echo "ERROR: $arg is not set"
    exit 1
  fi
done

BASE_DIR=/home/ubuntu/aws-cloud-controller-manager
helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
helm repo update
helm fetch aws-cloud-controller-manager/aws-cloud-controller-manager 
tar -xvf aws-cloud-controller-manager-*.tgz -C ${BASE_DIR}
rm aws-cloud-controller-manager-*.tgz

# Use 'sed' to add the annotation to the file
sed -i "s|metadata:|metadata:\n  annotations:\n    ${ROLE_ANN}|" \
  "${BASE_DIR}/templates/clusterrolebinding.yaml"

VALUES_DIR=/home/ubuntu/values/aws-cloud-controller-manager
mkdir -p ${VALUES_DIR}
cat <<EOF | tee ${VALUES_DIR}/values.yaml
args:
  - --v=2
  - --cloud-provider=aws
  - --configure-cloud-routes=false
EOF

helm package ${BASE_DIR} --destination /home/ubuntu

helm install aws-cloud-controller-manager /home/ubuntu/aws-cloud-controller-manager-*.tgz \
  -f ~/values/aws-cloud-controller-manager/values.yaml \
  --namespace ${AWS_CLOUD_PROVIDER_SA_NAMESPACE}