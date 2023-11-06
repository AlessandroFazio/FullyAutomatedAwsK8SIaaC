#!/bin/bash

set -ex

SERVICE_ACCOUNT_ANN=${1}
NAMESPACE=${2}

required_args=(
  SERVICE_ACCOUNT_ANN
  NAMESPACE
)

for arg in "${required_args[@]}"; do
  if [[ -z "${!arg}" ]]; then
    echo "ERROR: $arg is not set"
    exit 1
  fi
done

BASE_DIR=/home/ubuntu
mkdir -p ${BASE_DIR}/storage-classes

cat <<EOF | tee ${BASE_DIR}/values.yaml
controller:
  serviceAccount:
    create: true
    name: ebs-csi-controller
    annotations:
      ${SERVICE_ACCOUNT_ANN}
    automountServiceAccountToken: true

node:
  serviceAccount:
    create: true
    name: ebs-csi-node
    automountServiceAccountToken: true
EOF

# Install EBS CSI Driver with Helm
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update
helm upgrade --install aws-ebs-csi-driver \
    --namespace kube-system \
    aws-ebs-csi-driver/aws-ebs-csi-driver

cat <<EOF | tee ~/storage-classes/aws-ebs-xfs-storage-class.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-xfs-sc
provisioner: ebs.csi.aws.com
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
parameters:
  csi.storage.k8s.io/fstype: xfs
  type: io1
  iopsPerGB: "50"
  encrypted: "true"
EOF

cat <<EOF | tee ~/storage-classes/aws-ebs-ext4-storage-class.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-ext4-sc
provisioner: ebs.csi.aws.com
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
parameters:
  csi.storage.k8s.io/fstype: ext4
  type: io1
  iopsPerGB: "50"
  encrypted: "true"
EOF

cat <<EOF | tee ~/storage-classes/aws-ebs-ssd-gp3-storage-class.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-ssd-gp3-sc
provisioner: ebs.csi.aws.com
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
parameters:
  csi.storage.k8s.io/fstype: ext4
  type: gp3
  iops: "3000"
  encrypted: "true"
EOF

kubectl apply -f ~/storage-classes/
