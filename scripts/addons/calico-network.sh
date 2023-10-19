#!/bin/bash

# This script is used to generate the custom-resources.yaml file that is used to configure Calico.
# It is intended to be run on the first controlplane node.

K8S_POD_NETWORK_CIDR=$1

if [ -z "${K8S_POD_NETWORK_CIDR}" ]; then
  echo "Usage: $0 <pod-network-cidr>"
  exit 1
fi

cat <<EOF | tee ~/calico/custom-resources.yaml
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