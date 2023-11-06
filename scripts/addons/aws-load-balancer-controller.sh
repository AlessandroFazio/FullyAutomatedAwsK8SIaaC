#!/bin/bash

set -ex

K8S_CLUSTER_NAME=${1}
NAMESPACE=${2}
AWS_LOAD_BALANCER_CONTROLLER_ANN=${3}

required_args=(
    K8S_CLUSTER_NAME
    NAMESPACE
    AWS_LOAD_BALANCER_CONTROLLER_ANN
)

for arg in "${required_args[@]}"; do
  if [ -z "${!arg}" ]; then
    echo "${arg} is required"
    exit 1
  fi
done

BASE_DIR=/home/ubuntu/aws-load-balancer-controller
mkdir -p ${BASE_DIR}

cat <<EOF | tee ${BASE_DIR}/serviceaccount.yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    ${AWS_LOAD_BALANCER_CONTROLLER_ANN}
  name: aws-load-balancer-controller
  namespace: ${NAMESPACE}
  automountServiceAccountToken: true
---
EOF

cat <<EOF | tee ${BASE_DIR}/values.yaml
---
clusterName: ${K8S_CLUSTER_NAME}
serviceAccount:
  create: false
  name: aws-load-balancer-controller
EOF

kubectl apply -f ${BASE_DIR}/serviceaccount.yaml

helm repo add eks https://aws.github.io/eks-charts
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace ${NAMESPACE} \
    -f ${BASE_DIR}/values.yaml 





