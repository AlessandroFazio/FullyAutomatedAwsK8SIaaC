#!/bin/bash

set -xe

function check_required_args() {
    local args=("$@")

    for arg in "${args[@]}"; do
        if [ -z "${!arg}" ]; then
            echo "${arg} is required"
            exit 1
        fi
    done
}

function set_hostname() {
  local hostname_mode=$1
  local hostname=""
  if [ "${hostname_mode}" == "private-ip" ]; then
    hostname=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname)
  elif [ "${hostname_mode}" == "instance-id" ]; then
    hostname=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
  else 
    echo "K8S_NODES_HOSTNAME_MODE must be either private-ip or instance-id"
    echo "Got ${hostname_mode}"
    exit 1
  fi

  sudo hostnamectl set-hostname "${hostname}" --static
}

function setup_host_network() {
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
}

function prepare_for_calico_cni() {
    sudo mkdir -p /etc/NetworkManager/conf.d/
    sudo bash -c "cat <<EOF | tee /etc/NetworkManager/conf.d/calico.conf
    [keyfile]
    unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
    EOF"
}

function prepare_for_cni() {
    local cni=$1
    
    if [ "${cni}" == "calico" ]; then
        prepare_for_calico_cni
    else 
        echo "CNI ${cni} is not supported"
        exit 1
    fi
}

function initialize_system() {
  hostname_mode=$1
  set_hostname "${hostname_mode}"

  setup_host_network

  # apply sysctl configurations
  sudo sysctl --system
}

function install_and_configure_containerd() {
    sudo apt-get install -y containerd
    sudo mkdir -p /etc/containerd
    sudo containerd config default | sudo tee /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' config.toml

    sudo systemctl restart containerd
}

function install_and_configure_k8s_comps() {
  local k8s_version=$1
  sudo apt-get install -y apt-transport-https curl

  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

  cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF

  sudo apt update
  sudo apt install -y \
      kubeadm="${k8s_version}.1-00" \
      kubelet="${k8s_version}.1-00" \
      kubectl="${k8s_version}.1-00"

  cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
}

function install_packages() {
  local k8s_version=$1
  # install necessary packages
  install_and_configure_containerd
  install_and_configure_k8s_comps "${k8s_version}"
}

function get_controlplane_endpoint() {
    local cluster_name=$1
    local response=$(aws elbv2 describe-load-balancers \
                    --names ${cluster_name}-controlplane-nlb \
                    --query 'LoadBalancers[?State.Code==\`active\`].DNSName' \
                    --output text)
     if [ -z "$response" ]; then
        echo "controlplane-nlb endpoint not found"
        exit 1
    fi
    echo $response
}

function get_controlplane_join_cmd() {
    local cluster_name=$1
    local response=$(aws secretsmanager get-secret-value \
                        --secret-id "kubernetes/${cluster_name}/cmd/join/controlplane" \
                        --query SecretString \
                        --output text)
    if [ -z "$response" ]; then
        echo "controlplane join command not found"
        exit 1
    fi
    echo $response
}

function create_kubeadm_config() {
    local config_filepath=$1
    local cluster_name=$2
    local controlplane_endpoint=$(get_controlplane_endpoint "${cluster_name}")
    local ipv4_addr=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
    local controlplane_join_cmd=$(get_controlplane_join_cmd "${cluster_name}")
    local cert_key=$(echo "${controlplane_join_cmd}" | awk '{print $10}')
    local token=$(echo "${controlplane_join_cmd}" | awk '{print $5}')
    local cert_hash=$(echo "${controlplane_join_cmd}" | awk '{print $7}')
  
    cat <<EOF | tee "${config_filepath}"
---
apiVersion: kubeadm.k8s.io/v1beta3
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
JoinControlPlane:
  localAPIEndpoint:
    advertiseAddress: ${ipv4_addr}
    bindPort: 6443
  certificateKey: "${cert_key}"
discovery:
  bootstrapToken:
    token: "${token}"
    apiServerEndpoint: "${controlplane_endpoint}:6443"
    caCertHashes:
      - "${cert_hash}"
nodeRegistration:
  name: $(hostname)
  kubeletExtraArgs:
    cloud-provider: external 
    container-runtime-endpoint: unix:///run/containerd/containerd.sock 
EOF
}

function run_kubeadm_join() {
  local config_filepath=$1
  local log_file=$2
  sudo kubeadm join --config "${config_filepath}" | tee "${log_file}"
}

### MAIN ###
# Usage: ./joining-controlplane.sh <K8S_CLUSTER_NAME> <K8S_VERSION> <K8S_NODES_HOSTNAME_MODE>
K8S_CLUSTER_NAME=$1
K8S_VERSION=$2
K8S_NODES_HOSTNAME_MODE=$3
CNI="calico"

# Constants
KUBEADM_CONFIG_FILEPATH="/home/ubuntu/kubeadm-config.yaml"
KUBEADM_LOG_FILEPATH="/home/ubuntu/kubeadm-join.out"

required_args=(
    K8S_CLUSTER_NAME
    K8S_VERSION
    K8S_NODES_HOSTNAME_MODE
)

check_required_args "${required_args[@]}"
initialize_system "${K8S_NODES_HOSTNAME_MODE}"
install_packages "${K8S_VERSION}"
prepare_for_cni "${CNI}"
create_kubeadm_config \
  "${KUBEADM_CONFIG_FILEPATH}" \
  "${K8S_CLUSTER_NAME}" 

run_kubeadm_init "${KUBEADM_CONFIG_FILEPATH}" "${KUBEADM_LOG_FILEPATH}"



