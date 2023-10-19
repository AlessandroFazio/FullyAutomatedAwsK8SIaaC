#!/bin/bash

BUCKET_NAME=$1
REGION=$2
SCRIPTS_DIR=$3

aws s3 cp ${SCRIPTS_DIR}/controlplane/first-controlplane.sh s3://${BUCKET_NAME}/scripts/controlplane/first-controlplane.sh
aws s3 cp ${SCRIPTS_DIR}/controlplane/joining-controlplane.sh s3://${BUCKET_NAME}/scripts/controlplane/joining-controlplane.sh
aws s3 cp ${SCRIPTS_DIR}/worker/worker.sh s3://${BUCKET_NAME}/scripts/worker/worker.sh

aws s3 cp ${SCRIPTS_DIR}/addons/calico-network.sh s3://${BUCKET_NAME}/scripts/addons/calico-network.sh
# aws s3 cp ${SCRIPTS_DIR}/addons/dashboard.sh s3://${BUCKET_NAME}/scripts/addons/dashboard.sh TODO 
aws s3 cp ${SCRIPTS_DIR}/addons/cluster-autoscaler.sh s3://${BUCKET_NAME}/scripts/addons/cluster-autoscaler.sh
aws s3 cp ${SCRIPTS_DIR}/addons/k8s-drainer-bootstrap.sh s3://${BUCKET_NAME}/scripts/addons/k8s-drainer-bootstrap.sh
aws s3 cp ${SCRIPTS_DIR}/addons/metrics-server.yaml s3://${BUCKET_NAME}/scripts/addons/metrics-server.yaml