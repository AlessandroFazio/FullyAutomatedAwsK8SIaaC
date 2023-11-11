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

function initialize_system() {
  hostname_mode=$1
  set_hostname "${hostname_mode}"

  setup_host_network

  # apply sysctl configurations
  sudo sysctl --system
}

function install_utils() {
  sudo apt update -y
  sudo apt install -y jq
  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  sudo chmod +x /usr/local/bin/yq
  sudo apt install -y default-jre
}

function install_helm() {
    curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
    sudo apt-get install apt-transport-https --yes
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
    sudo apt-get update
    sudo apt-get install helm
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
  install_utils
  install_helm
  install_and_configure_containerd
  install_and_configure_k8s_comps "${k8s_version}"
}

# Function to wait for resources to become available
function wait_for_resources() {
  local timeout="$1"
  local message="$2"
  local check_command="$3"
  
  timeout "${timeout}" bash -c \
    "until ${check_command}; do printf '.'; sleep 5; done"
}

function get_nlb_dns() {
  local k8s_cluster_name=$1
  local response=$(aws elbv2 describe-load-balancers \
    --names "${k8s_cluster_name}-controlplane-nlb" \
    --query 'LoadBalancers[?State.Code==`active`].DNSName' \
    --output text)
  
  if [ -z "${response}" ]; then
    echo "controlplane-nlb not found. Exiting..."
    exit 1
  fi

  echo "${response}"
}

function get_host_from_url() {
  local url=$1
  echo "${url}" | cut -d'/' -f3
}

function get_oidc_cacert() {
  local oidc_provider_url=$1
  local domain_name=$(get_host_from_url "${oidc_provider_url}")
  local crt_arn=$(aws acm list-certificates \
    --query "CertificateSummaryList[?DomainName=='${domain_name}'] | [0].CertificateArn" \
    --output text)
  
  if [ -z "${crt_arn}" ]; then
    echo "OIDC_URL certificate not found. Exiting..."
    exit 1
  fi

  local crt=$(aws acm get-certificate \
    --certificate-arn "${crt_arn}" \
    --query CertificateChain \
    --output text) 
  
  if [ -z "${crt}" ]; then
    echo "OIDC_URL certificate not found. Exiting..."
    exit 1
  fi

  echo "${crt}" > keycloak-ca-chain.crt
}

function get_oidc_privkey() {
  local oidc_privkey_secret_id=$1
  local oidc_privkey=$(aws secretsmanager get-secret-value \
    --secret-id "${oidc_privkey_secret_id}" \
    --query SecretString \
    --output text)
  
  if [ -z "${oidc_privkey}" ]; then
    echo "OIDC_KEY not found. Exiting..."
    exit 1
  fi

  echo "${oidc_privkey}" > sa-signer.key
}

function get_oidc_pubkey() {
  local oidc_provider_url=$1
  local oidc_pubkey=$(curl -s https://"${oidc_provider_url}"/realm/kubernetes | jq '.public_key' | tr -d '"')
  local frmt_oidc_pubkey="-----BEGIN PUBLIC KEY-----\n$(echo -n "${oidc_pubkey}" | fold -w64)\n-----END PUBLIC KEY-----"
  echo -e "${frmt_oidc_pubkey}" > sa-signer-pkcs8.pub
}

function prepare_oidc_resources() {
  local oidc_provider_url=$1
  local oidc_privkey_secret_id=$2

  get_oidc_cacert "${oidc_provider_url}"
  get_oidc_privkey "${oidc_privkey_secret_id}"
  get_oidc_pubkey "${oidc_provider_url}"

  sudo mkdir -p /etc/ssl/keycloak/certs
  sudo mv keycloak-ca-chain.crt /etc/ssl/keycloak/certs
  sudo chmod 644 /etc/ssl/keycloak/certs/keycloak-ca-chain.crt

  sudo mkdir -p /etc/keys/keycloak/
  sudo mv sa-signer.key /etc/keys/keycloak/
  sudo mv sa-signer-pkcs8.pub /etc/keys/keycloak/

  sudo chmod 600 /etc/keys/keycloak/sa-signer.key
  sudo chmod 644 /etc/keys/keycloak/sa-signer-pkcs8.pub
}

function create_kubeadm_config() {
  local config_filepath=$1
  local cluster_name=$2
  local pod_network_cidr=$3
  local cluster_service_cidr=$4
  local cluster_default_dns=$5
  local oidc_provider_url=$6
  local oidc_client_id=$7
  local oidc_username_claim=$8
  local oidc_groups_claim=$9

  local nlb_dns=$(get_nlb_dns "${cluster_name}")
  local ipv4_addr=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
  
  cat <<EOF | tee "${config_filepath}"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
controlPlaneEndpoint: ${nlb_dns}:6443
APIEndpoint:
  advertiseAddress: ${ipv4_addr}
  bindPort: 6443
networking:
podSubnet: ${pod_network_cidr}
serviceSubnet: 
dnsDomain: ${cluster_default_dns}
clusterName: ${cluster_name}
apiServer:
  extraArgs:
    cloud-provider: external
    oidc-issuer-url: ${oidc_provider_url}
    oidc-client-id: ${oidc_client_id}
    oidc-ca-file: /etc/kubernetes/ssl/keycloak/keycloak-ca-chain.crt
    oidc-username-claim: ${oidc-username-claim}
    oidc-groups-claim: ${oidc-groups-claim}
    api-audiences: sts.amazonaws.com
    service-account-issuer: ${oidc_provider_url}
    service-account-key-file: /etc/kubernetes/keys/keycloak/sa-signer-pkcs8.pub
    service-account-signing-key-file: /etc/kubernetes/keys/keycloak/sa-signer.key
  extraVolumes:
  - name: keycloak-certs
    hostPath: "/etc/ssl/keycloak/certs"
    mountPath: "/etc/kubernetes/ssl/keycloak/"
    readOnly: true
    pathType: Directory
  - name: keycloak-keys
    hostPath: "/etc/keys/keycloak/"
    mountPath: "/etc/kubernetes/keys/keycloak/"
    readOnly: true
    pathType: Directory
controllerManager:
  extraArgs:
    cloud-provider: external
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  name: $(hostname)
  kubeletExtraArgs:
    cloud-provider: external
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
EOF
}

function run_kubeadm_init() {
  local config_filepath=$1
  local log_file=$2
  sudo kubeadm init --config "${config_filepath}" --upload-certs | tee "${log_file}"
}

function configure_kubectl() {
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  echo "alias k=kubectl" >> .bashrc
  echo "alias ka='kubectl apply -f'" >> .bashrc
  echo "alias kr='kubectl replace -f'" >> .bashrc
  echo "alias kd='kubectl delete -f'" >> .bashrc
}

function get_cmd_from_logfile() {
  local log_file=$1
  local regex=$2
  local cmd_start_line=$3
  local cmd=$(sudo cat "${log_file}" \
    | grep -i "${regex}" -A1 \
    | grep -v "${cmd_start_line}")
  
  if [ -z "${cmd}" ]; then
    echo "Command not found in log file. Exiting..."
    exit 1
  fi

  echo "${cmd}"
}

function upload_cmd_to_sm() {
  local cluster_name=$1
  local identifier=$2
  local cmd=$2
  aws secretsmanager create-secret \
    --name "kubernetes/${cluster_name}/cmd/join/${identifier}" \
    --secret-string "${cmd}"
}

function upload_join_cmd() {
  local cluster_name=$1
  local log_file=$2
  local regex=$3
  local cmd_start_line=$4
  local identifier=$5

  local cmd=$(get_cmd_from_logfile "${log_file}" "${regex}" "${cmd_start_line}")
  upload_cmd_to_sm "${cluster_name}" "${identifier}" "${cmd}"
}

function setup_calico_cni() {
  local cni=$1
  local pods_network_cidr=$2
  local s3_bucket=$3

  kubectl taint nodes --all node-role.kubernetes.io/control-plane-
  aws s3 cp s3://${s3_bucket}/scripts/addons/calico.sh /tmp/calico.sh
  chmod +x /tmp/calico.sh
  bash /tmp/calico.sh "${pods_network_cidr}"
}

function setup_cni() {
  local cni=$1
  local pods_network_cidr=$2
  local s3_bucket=$3

  if [ "${cni}" == "calico" ]; then
    setup_calico_cni "${cni}" "${pods_network_cidr}" "${s3_bucket}"
  else
    echo "CNI not yet supported. Exiting..."
    exit 1
  fi
}

function scale_controlplane() {
  local asg_name=$1
  local desired_capacity=$2
  aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "${asg_name}" \
  --desired-capacity "${desired_capacity}"

  if [ $? -ne 0 ]; then
  echo "Error: Failed to scale controlplane ASG"
  exit 1  
  fi
}

function install_addon() {
  local s3_bucket="$1"
  local s3_base_path="$2"
  local script_name="$3"
  local local_addon_dir="$4"
  local args="${@:5}"

  aws s3 cp s3://${s3_bucket}/${s3_base_path}/${script_name} ${local_addon_dir}/${script_name}
  chmod +x ${local_addon_dir}/${script_name}
  bash ${local_addon_dir}/${script_name} ${args}
}

### MAIN ###
# Usage: ./k8s-bootstrap-master-aws-calico-vxlan.sh <cluster-name> <k8s-version> <pod-network-cidr> <cluster-service-cidr> <cluster-default-dns>
K8S_CLUSTER_NAME=${1}
K8S_VERSION=${2}
K8S_POD_NETWORK_CIDR=${3}
K8S_CLUSTER_SERVICE_CIDR=${4}
K8S_CLUSTER_DEFAULT_DNS=${5}
K8S_NODES_HOSTNAME_MODE=${6}
CONTROLPLANE_ASG_NAME=${7}
CONTROLPLANE_ASG_DESIRED_CAPACITY=${8}
S3_BUCKET=${9}
OIDC_PROVIDER_URL=${10}
OIDC_KEY_SECRET_ID=${11}
OIDC_CLIENT_ID=${12}
OIDC_USERNAME_CLAIM=${13}
OIDC_GROUPS_CLAIM=${14}
EKS_IRSA_WEBHOOK_SA_NAMESPACE=${15}
EBS_CSI_DRIVER_SA_NAMESPACE=${16}
EBS_CSI_DRIVER_ROLE_ARN=${17}
AWS_CLOUD_PROVIDER_SA_NAMESPACE=${18}
AWS_CLOUD_PROVIDER_ROLE_ARN=${19}
AWS_LOAD_BALANCER_CONTROLLER_SA_NAMESPACE=${20}
AWS_LOAD_BALANCER_CONTROLLER_ROLE_ARN=${21}
CLUSTER_AUTO_SCALER_SA_NAMESPACE=${22}
CLUSTER_AUTO_SCALER_ROLE_ARN=${23}
NTH_NAMESPACE=${24}
NTH_SQS_URL=${25}
NTH_ROLE_ARN=${26}
CNI="calico"

# Constants
KUBEADM_CONFIG_FILEPATH="kubeadm-config.yaml"
KUBEADM_LOG_FILEPATH="kubeadm-init.out"
TAINT_NETWORK_NOT_READY="node.kubernetes.io/network-unavailable:NoSchedule"
S3_ADDONS_BASE_PATH="scripts/addons"
LOCAL_ADDONS_DIR="/tmp"
IRSA_ANN_KEY="eks.amazonaws.com/role-arn"

required_args=(
  K8S_CLUSTER_NAME
  K8S_VERSION
  K8S_POD_NETWORK_CIDR
  K8S_CLUSTER_SERVICE_CIDR
  K8S_CLUSTER_DEFAULT_DNS
  K8S_NODES_HOSTNAME_MODE
  CONTROLPLANE_ASG_NAME
  CONTROLPLANE_ASG_DESIRED_CAPACITY
  S3_BUCKET
  OIDC_PROVIDER_URL
  OIDC_KEY_SECRET_ID
  OIDC_CLIENT_ID
  OIDC_USERNAME_CLAIM
  OIDC_GROUPS_CLAIM
  EKS_IRSA_WEBHOOK_SA_NAMESPACE
  EBS_CSI_DRIVER_SA_NAMESPACE
  EBS_CSI_DRIVER_ROLE_ARN
  AWS_CLOUD_PROVIDER_SA_NAMESPACE
  AWS_CLOUD_PROVIDER_ROLE_ARN
  AWS_LOAD_BALANCER_CONTROLLER_SA_NAMESPACE
  AWS_LOAD_BALANCER_CONTROLLER_ROLE_ARN
  CLUSTER_AUTO_SCALER_SA_NAMESPACE
  CLUSTER_AUTO_SCALER_ROLE_ARN
  NTH_NAMESPACE
  NTH_SQS_URL
  NTH_ROLE_ARN
)

check_required_args "${required_args[@]}"
initialize_system "${K8S_NODES_HOSTNAME_MODE}"
install_packages "${K8S_VERSION}"
wait_for_resources 600 "OidcProvider is not up" "curl --silent --head --fail https://${OIDC_PROVIDER_URL}"
prepare_oidc_resources "${OIDC_PROVIDER_URL}" "${OIDC_KEY_SECRET_ID}"
wait_for_resources 600 "Waiting for NLB to be up" "aws elbv2 describe-load-balancers \
                                                    --names \"${K8S_CLUSTER_NAME}-controlplane-nlb\" \
                                                    --query \"LoadBalancers[?State.Code==`active`].DNSName\" \
                                                    --output text"
create_kubeadm_config \
  "${KUBEADM_CONFIG_FILEPATH}" \
  "${K8S_CLUSTER_NAME}" \
  "${K8S_POD_NETWORK_CIDR}" \
  "${K8S_CLUSTER_SERVICE_CIDR}" \
  "${K8S_CLUSTER_DEFAULT_DNS}" \
  "${OIDC_PROVIDER_URL}" \
  "${OIDC_CLIENT_ID}" \
  "${OIDC_USERNAME_CLAIM}" \
  "${OIDC_GROUPS_CLAIM}"

run_kubeadm_init "${KUBEADM_CONFIG_FILEPATH}" "${KUBEADM_LOG_FILEPATH}"
configure_kubectl
upload_join_cmd \
  "${K8S_CLUSTER_NAME}" \
  "${KUBEADM_LOG_FILEPATH}" \
  "You can now join any number of control-plane node by running the following command" \
  "kubeadm join" \
  "controlplane"

upload_join_cmd \
  "${K8S_CLUSTER_NAME}" \
  "${KUBEADM_LOG_FILEPATH}" \
  "you can join any number of worker nodes by running the following" \
  "kubeadm join" \
  "worker"

setup_cni "${CNI}" "${K8S_POD_NETWORK_CIDR}" "${S3_BUCKET}"
wait_for_resources 300 "Waiting for taint on node to be removed" \
  "kubectl describe node '$(hostname)' | grep 'Taints' | grep -q -v '${TAINT_NETWORK_NOT_READY}' 2>/dev/null"

install_addon \
  "${S3_BUCKET}" \
  "${S3_ADDONS_BASE_PATH}" \
  "eks-irsa-webhook.sh" \
  "${LOCAL_ADDONS_DIR}" \
  "${EKS_IRSA_WEBHOOK_SA_NAMESPACE}" \
  "amazon/amazon-eks-pod-identity-webhook:latest"

kubectl taint nodes --all node-role.kubernetes.io/control-plane=:NoSchedule

install_addon \
  "${S3_BUCKET}" \
  "${S3_ADDONS_BASE_PATH}" \
  "aws-cloud-provider.sh" \
  "${LOCAL_ADDONS_DIR}" \
  "${AWS_CLOUD_PROVIDER_SA_NAMESPACE}" \
  "${IRSA_ANN_KEY}: ${AWS_CLOUD_PROVIDER_ROLE_ARN}"

install_addon \
  "${S3_BUCKET}" \
  "${S3_ADDONS_BASE_PATH}" \
  "cluster-autoscaler.sh" \
  "${LOCAL_ADDONS_DIR}" \
  "${K8S_CLUSTER_NAME}" \
  "${CLUSTER_AUTO_SCALER_SA_NAMESPACE}" \
  "${IRSA_ANN_KEY}: ${CLUSTER_AUTO_SCALER_ROLE_ARN}"

install_addon \
  "${S3_BUCKET}" \
  "${S3_ADDONS_BASE_PATH}" \
  "aws-load-balancer-controller.sh" \
  "${LOCAL_ADDONS_DIR}" \
  "${K8S_CLUSTER_NAME}" \
  "${AWS_LOAD_BALANCER_CONTROLLER_SA_NAMESPACE}" \
  "${IRSA_ANN_KEY}: ${AWS_LOAD_BALANCER_CONTROLLER_ROLE_ARN}"

install_addon \
  "${S3_BUCKET}" \
  "${S3_ADDONS_BASE_PATH}" \
  "external-snapshotter.sh" \
  "${LOCAL_ADDONS_DIR}" \
  "${EBS_CSI_DRIVER_SA_NAMESPACE}"

install_addon \
  "${S3_BUCKET}" \
  "${S3_ADDONS_BASE_PATH}" \
  "aws-ebs-csi-driver.sh" \
  "${LOCAL_ADDONS_DIR}" \
  "${K8S_CLUSTER_NAME}" \
  "${EBS_CSI_DRIVER_SA_NAMESPACE}" \
  "${IRSA_ANN_KEY}: ${EBS_CSI_DRIVER_ROLE_ARN}"

install_addon \
  "${S3_BUCKET}" \
  "${S3_ADDONS_BASE_PATH}" \
  "node-termination-handler.sh" \
  "${LOCAL_ADDONS_DIR}" \
  "${NTH_NAMESPACE}" \
  "${NTH_SQS_URL}" \
  "0.22.0" \
  "${IRSA_ANN_KEY}: ${NTH_ROLE_ARN}"

install_addon \
  "${S3_BUCKET}" \
  "${S3_ADDONS_BASE_PATH}" \
  "metrics-server.sh" \
  "${LOCAL_ADDONS_DIR}"
