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

sudo swapoff -a
sudo sysctl net.ipv4.ip_forward=1
sudo sysctl -w vm.max_map_count=262144

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

sudo systemctl restart containerd
sudo service containerd status


cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

sudo apt-get update -y && sudo apt-get upgrade -y
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

sudo systemctl restart containerd

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' config.toml

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
                    --query 'LoadBalancers[?Tags[?Key==`Name` && Value==`controlplane-nlb`]].DNSName'  \
                    --output text)
  if [ -z "$response" ]; then
    echo "controlplane-nlb not found"
    exit 1
  fi
  echo $response
}

function get_worker_join_cmd() {
  local response=$(aws ssm get-parameter \
                    --name "/kubernetes/${K8S_CLUSTER_NAME}/cmd/join/worker" \
                    --query 'Parameter.Value' \
                    --output text)
  if [ -z "$response" ]; then
    echo "worker join command not found"
    exit 1
  fi
  echo $response
}

CONTROLPLANE_ENDPOINT=$(get_worker_join_cmd)
JOIN_WORKER_CMD=$(get_controlplane_join_cmd)
TOKEN=$(echo "${JOIN_WORKER_CMD}" | awk '{print $5}')
CERT_HASH=$(echo "${JOIN_WORKER_CMD}" | awk '{print $7}')

cat <<EOF | tee kubeadm-join-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    token: "${TOKEN}"
    apiServerEndpoint: "${CONTROLPLANE_ENDPOINT}:6443"
    caCertHashes:
      - "${CERT_HASH}"
nodeRegistration:
  name: "$(hostname -f)"
  kubeletExtraArgs:
    cloud-provider: external 
    container-runtime-endpoint: unix:///run/containerd/containerd.sock
EOF

sudo kubeadm join --config kubeadm-join-config.yaml