#!/bin/bash

set -ex

K8S_POD_NETWORK_CIDR=$1

required_args=(
  K8S_POD_NETWORK_CIDR
)

for arg in "${required_args[@]}"; do
  if [[ -z "${!arg}" ]]; then
    echo "ERROR: $arg is not set"
    exit 1
  fi
done

sudo mkdir -p /etc/NetworkManager/conf.d/
sudo bash -c "cat <<EOF | tee /etc/NetworkManager/conf.d/calico.conf
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF"

BASE_DIR=/home/ubuntu/calico
mkdir -p ${BASE_DIR}
wget https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml \
  -O ${BASE_DIR}/tigera-operator.yaml
kubectl create -f ${BASE_DIR}/tigera-operator.yaml

cat <<EOF | tee ${BASE_DIR}/custom-resources.yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    bgp: Enabled
    ipPools:
    - blockSize: 26
      cidr: "${K8S_POD_NETWORK_CIDR}"
      encapsulation: IPIP
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

kubectl create -f ${BASE_DIR}/custom-resources.yaml

curl -L https://github.com/projectcalico/calico/releases/download/v3.26.1/calicoctl-linux-amd64 -o calicoctl
chmod +x ./calicoctl
sudo mv calicoctl /usr/local/bin/
