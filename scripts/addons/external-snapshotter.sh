#!/bin/bash

set -ex

NAMESPACE=${1}

required_args=(
  NAMESPACE
)

for arg in "${required_args[@]}"; do
  if [[ -z "${!arg}" ]]; then
    echo "ERROR: $arg is not set"
    exit 1
  fi
done

BASE_DIR=/home/ubuntu/external-snapshotter
git clone https://github.com/kubernetes-csi/external-snapshotter.git ${BASE_DIR}
kubectl kustomize ${BASE_DIR}/client/config/crd | kubectl create -f -
kubectl -n ${NAMESPACE} kustomize ${BASE_DIR}/deploy/kubernetes/snapshot-controller | kubectl create -f -

mkdir -p /home/ubuntu/snapshot-classes
cat <<EOF | tee /home/ubuntu/snapshot-classes/aws-ebs-snapshot-class.yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-aws-vsc
driver: ebs.csi.aws.com
deletionPolicy: Delete
EOF

kubectl apply -f /home/ubuntu/snapshot-classes/aws-ebs-snapshot-class.yaml
