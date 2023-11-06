#!/bin/bash

# Usage: ./joining-controlplane.sh <K8S_VERSION> 
K8S_CLUSTER_NAME=$1
K8S_VERSION=$2
K8S_NODES_HOSTNAME_MODE=$3

if [ -z "${K8S_CLUSTER_NAME}" ]; then
  echo "K8S_CLUSTER_NAME is required"
  exit 1
fi

if [ -z "${K8S_VERSION}" ]; then
  echo "K8S_VERSION is required"
  exit 1
fi

if [ -z "${K8S_NODES_HOSTNAME_MODE}" ]; then
  echo "K8S_NODES_HOSTNAME_MODE is required"
  exit 1
fi

HOSTNAME=""
if [ "${K8S_NODES_HOSTNAME_MODE}" == "private-ip" ]; then
  HOSTNAME=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname)
elif [ "${K8S_NODES_HOSTNAME_MODE}" == "instance-id" ]; then
  HOSTNAME=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
else 
  echo "K8S_NODES_HOSTNAME_MODE must be either private-ip or instance-id"
  echo "Got ${K8S_NODES_HOSTNAME_MODE}"
  exit 1
fi

sudo hostnamectl set-hostname "${HOSTNAME}" --static

# disable swap and enable ip forwarding
sudo swapoff -a
sudo sysctl net.ipv4.ip_forward=1
sudo sysctl -w vm.max_map_count=262144

# prepare containerd runtime
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

# load modules
sudo modprobe overlay
sudo modprobe br_netfilter

# set system configurations
cat <<EOF | sudo tee etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

# apply sysctl configurations
sudo sysctl --system

# install necessary packages
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
sudo apt install -y default-jre

curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
sudo apt-get install apt-transport-https --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm

sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' config.toml

sudo systemctl restart containerd

sudo apt-get update && sudo apt-get install -y apt-transport-https curl

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF

sudo apt update
sudo apt install -y \
    kubeadm="${K8S_VERSION}.1-00" \
    kubelet="${K8S_VERSION}.1-00" \
    kubectl="${K8S_VERSION}.1-00"

cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

sudo mkdir -p /etc/NetworkManager/conf.d/
sudo bash -c "cat <<EOF | tee /etc/NetworkManager/conf.d/calico.conf
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF"

function get_controlplane_endpoint() {
  local response=$(aws elbv2 describe-load-balancers \
                    --names ${K8S_CLUSTER_NAME}-controlplane-nlb \
                    --query 'LoadBalancers[?State.Code==\`active\`].DNSName' \
                    --output text)
  if [ -z "$response" ]; then
    echo "controlplane-nlb not found"
    exit 1
  fi
  echo $response
}

function get_controlplane_join_cmd() {
  local response=$(aws secretsmanager get-secret-value \
                    --secret-id "kubernetes/${K8S_CLUSTER_NAME}/cmd/join/controlplane" \
                    --query SecretString \
                    --output text)
  if [ -z "$response" ]; then
    echo "controlplane join command not found"
    exit 1
  fi
  echo $response
}

CONTROLPLANE_ENDPOINT=$(get_controlplane_endpoint)
JOIN_CONTROLPLANE_CMD=$(get_controlplane_join_cmd)
CERT_KEY=$(echo "${JOIN_CONTROLPLANE_CMD}" | awk '{print $10}')
TOKEN=$(echo "${JOIN_CONTROLPLANE_CMD}" | awk '{print $5}')
CERT_HASH=$(echo "${JOIN_CONTROLPLANE_CMD}" | awk '{print $7}')

cat <<EOF | tee kubeadm-join-config.yaml
---
apiVersion: kubeadm.k8s.io/v1beta3
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
JoinControlPlane:
  localAPIEndpoint:
    advertiseAddress: "$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
    bindPort: 6443
  certificateKey: "${CERT_KEY}"
discovery:
  bootstrapToken:
    token: "${TOKEN}"
    apiServerEndpoint: "${CONTROLPLANE_ENDPOINT}:6443"
    caCertHashes:
      - "${CERT_HASH}"
nodeRegistration:
  name: ${HOSTNAME}
  kubeletExtraArgs:
    cloud-provider: external 
    container-runtime-endpoint: unix:///run/containerd/containerd.sock 
EOF

sudo kubeadm join --config kubeadm-join-config.yaml

