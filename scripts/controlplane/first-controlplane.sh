#!/bin/bash

set -xe

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
OIDC_PROXY_DNS=${10}
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
  OIDC_PROXY_DNS
  OIDC_KEY_SECRET_ID
  OIDC_CLIENT_ID
  OIDC_USERNAME_CLAIM
  OIDC_GROUPS_CLAIM
  EBS_CSI_DRIVER_SA_NAMESPACE
  EBS_CSI_DRIVER_ROLE_ARN
  AWS_CLOUD_PROVIDER_SA_NAMESPACE
  AWS_CLOUD_PROVIDER_ROLE_ARN
  AWS_LOAD_BALANCER_CONTROLLER_SA_NAMESPACE
  AWS_LOAD_BALANCER_CONTROLLER_ROLE_ARN
  CLUSTER_AUTO_SCALER_SA_NAMESPACE
  CLUSTER_AUTO_SCALER_ROLE_ARN
)

for arg in "${required_args[@]}"; do
  if [ -z "${!arg}" ]; then
    echo "${arg} is required"
    exit 1
  fi
done

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
curl kttps://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-x86_64.zip
unzip aws-sam-cli-linux-x86_64.zip -d sam-installation
sudo ./sam-installation/install

sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
sudo apt install -y default-jre

curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash
sudo mv ./kustomize  /usr/local/bin/kustomize
export PATH=$PATH:/usr/local/bin/kustomize

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

timeout 600 bash -c \
  "until curl --silent --head --fail https://${OIDC_PROXY_DNS}; do printf '.'; sleep 5; done"

function is_controlplane_nlb_up() {
  if [ -z "$(aws elbv2 describe-load-balancers \
    --names "${K8S_CLUSTER_NAME}-controlplane-nlb" \
    --query 'LoadBalancers[?State.Code==`active`].DNSName' \
    --output text)" ]; then
    return 1;
  fi
  return 0;
}

timeout 600 bash -c \
  "until is_controlplane_nlb_up; do printf '.'; sleep 5; done"

nlb_dns=$(aws elbv2 describe-load-balancers \
  --names ${K8S_CLUSTER_NAME}-controlplane-nlb \
  --query 'LoadBalancers[?State.Code==\`active\`].DNSName' \
  --output text)

if [ -z "${nlb_dns}" ]; then
  echo "controlplane-nlb not found"
  exit 1
fi

CRT_ARN=$(aws acm list-certificates \
  --query "CertificateSummaryList[?DomainName=='${OIDC_PROXY_DNS}'] | [0].CertificateArn" \
  --output text)

if [ -z "${CRT_ARN}" ]; then
  echo "OIDC_URL certificate not found"
  exit 1
fi

CRT=$(aws acm get-certificate \
  --certificate-arn "$CRT_ARN" \
  --query CertificateChain \
  --output text) 
  
if [ -z "${CRT}" ]; then
  echo "OIDC_URL certificate not found"
  exit 1
fi

echo ${CRT} > keycloak-ca-chain.crt 

sudo mkdir -p /etc/ssl/keycloak/certs
sudo mv keycloak-ca-chain.crt /etc/ssl/keycloak/certs
sudo chmod 644 /etc/ssl/keycloak/certs/keycloak-ca-chain.crt

OIDC_KEY=$(aws secretsmanager get-secret-value \
  --secret-id ${OIDC_KEY_SECRET_ID} \
  --query SecretString \
  --output text)

if [ -z "${OIDC_KEY}" ]; then
  echo "OIDC_KEY not found"
  exit 1
fi

echo ${OIDC_KEY} > sa-signer.key

oidc_public_key=$(curl -s https://${OIDC_PROXY_DNS}/realm/kubernetes | jq '.public_key' | tr -d '"')
frmt_oidc_pub_key="-----BEGIN PUBLIC KEY-----\n$(echo -n $oidc_public_key | fold -w64)\n-----END PUBLIC KEY-----"
echo -e "$frmt_oidc_pub_key" > sa-signer-pkcs8.pub

sudo mkdir -p /etc/keys/keycloak/
sudo mv sa-signer.key /etc/keys/keycloak/
sudo mv sa-signer-pkcs8.pub /etc/keys/keycloak/

sudo chmod 600 /etc/keys/keycloak/sa-signer.key
sudo chmod 644 /etc/keys/keycloak/sa-signer-pkcs8.pub

cat <<EOF | tee kubeadm-config.yaml
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
controlPlaneEndpoint: "${nlb_dns}:6443"
APIEndpoint:
  advertiseAddress: "$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
  bindPort: 6443
networking:
 podSubnet: "${K8S_POD_NETWORK_CIDR}"
 serviceSubnet: "${K8S_CLUSTER_SERVICE_CIDR}"
 dnsDomain: "${K8S_CLUSTER_DEFAULT_DNS}"
clusterName: "${K8S_CLUSTER_NAME}"
apiServer:
  extraArgs:
    cloud-provider: external
    oidc-issuer-url: https://${OIDC_PROXY_DNS}/realms/kubernetes
    oidc-client-id: ${OIDC_CLIENT_ID}
    oidc-ca-file: /etc/kubernetes/ssl/keycloak/keycloak-ca-chain.crt
    oidc-username-claim: ${OIDC_USERNAME_CLAIM}
    oidc-groups-claim: ${OIDC-GROUPS-CLAIM}
    api-audiences: sts.amazonaws.com
    service-account-issuer: https://${OIDC_PROXY_DNS}/realms/kubernetes
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
  name: ${HOSTNAME}
  kubeletExtraArgs:
    cloud-provider: external
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
EOF

sudo kubeadm init --config kubeadm-config.yaml --upload-certs | tee kubeadm-init.out

JOIN_CONTROLPLANE_CMD=$(sudo cat kubeadm-init.out \
  | grep -i "You can now join any number of control-plane node by running the following command" -A1 \
  | grep "kubeadm join")

JOIN_WORKER_CMD=$(sudo cat kubeadm-init.out \
  | grep -i "you can join any number of worker nodes by running the following" -A1 \
  | grep "kubeadm join")

aws secretsmanager create-secret \
  --name "kubernetes/${K8S_CLUSTER_NAME}/cmd/join/controlplane" \
  --secret-string "${JOIN_CONTROLPLANE_CMD}"

aws secretsmanager create-secret \
  --name "kubernetes/${K8S_CLUSTER_NAME}/cmd/join/worker" \
  --secret-string "${JOIN_WORKER_CMD}"

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "alias k=kubectl" >> .bashrc
echo "alias ka='kubectl apply -f'" >> .bashrc
echo "alias kr='kubectl replace -f'" >> .bashrc
echo "alias kd='kubectl delete -f'" >> .bashrc

aws cp s3://${S3_BUCKET}/scripts/addons/metrics-server.yaml /tmp/metrics-server.yaml
# kubectl apply -f /tmp/metrics-server.yaml TODO: check manifest if it's working

sudo mkdir -p /etc/NetworkManager/conf.d/
sudo bash -c "cat <<EOF | tee /etc/NetworkManager/conf.d/calico.conf
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF"

kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl taint nodes --all node-role.kubernetes.io/master-

mkdir ~/calico
wget https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml -O ~/calico/tigera-operator.yaml
kubectl create -f ~/calico/tigera-operator.yaml

aws s3 cp s3://${S3_BUCKET}/scripts/addons/calico-network.sh /tmp/calico.sh
chmod +x /tmp/calico.sh
bash /tmp/calico.sh "${K8S_POD_NETWORK_CIDR}"
kubectl create -f ~/calico/custom-resources.yaml

curl -L https://github.com/projectcalico/calico/releases/download/v3.26.1/calicoctl-linux-amd64 -o calicoctl
chmod +x ./calicoctl
sudo mv calicoctl /usr/local/bin/

function is_controlplane_available() {
   if [ -z "$(kubectl describe node "$(hostname)" \
      | grep Taint | grep node.kubernetes.io/network-unavailable:NoSchedule)" ]; then
      return 0;
   fi
   return 1;
}

timeout 300 bash -c "\
    until is_controlplane_available; do
        printf '.'
        sleep 5
    done"

aws s3 cp s3://${S3_BUCKET}/scripts/addons/eks-irsa-webhook.sh /tmp/eks-irsa-webhook.sh
chmod +x /tmp/eks-irsa-webhook.sh
EKS_IRSA_WEBHOOK_IMAGE="amazon/amazon-eks-pod-identity-webhook:latest"

bash /tmp/eks-irsa-webhook.sh \
  "${EKS_IRSA_WEBHOOK_SA_NAMESPACE}" \
  "${EKS_IRSA_WEBHOOK_IMAGE}"

kubectl taint nodes --all node-role.kubernetes.io/control-plane=:NoSchedule
kubectl taint nodes --all node-role.kubernetes.io/master=:NoSchedule

function get_ann() {
  local role_arn=$1
  echo "eks.amazonaws.com/role-arn: ${role_arn}"
}

helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws

helm repo update

helm fetch aws-cloud-controller-manager/aws-cloud-controller-manager --untar

mkdir -p ~/values/aws-cloud-controller-manager
cat <<EOF | tee ~/values/aws-cloud-controller-manager/values.yaml
args:
  - --v=2
  - --cloud-provider=aws
  - --configure-cloud-routes=false
EOF

# Use 'sed' to add the annotation to the file
sed -i "s|metadata:|metadata:\n  annotations:\n    $(get_ann "${AWS_CLOUD_PROVIDER_ROLE_ARN}")|" \
  "/home/ubuntu/aws-cloud-controller-manager/templates/serviceaccount.yaml"

helm install aws-cloud-controller-manager ./aws-cloud-controller-manager-0.0.8.tgz \
  -f ~/values/aws-cloud-controller-manager/values.yaml \
  --namespace ${AWS_CLOUD_PROVIDER_SA_NAMESPACE}

function retrieve_asg_names() {
  local response=$(aws autoscaling describe-auto-scaling-groups \
                    --query 'AutoScalingGroups[?Tags[?Key==`k8s.io/cluster-autoscaler/enabled`]].AutoScalingGroupName' \
                    --output text)
  if [ -z "${response}" ]; then
    echo "No ASG found"
    exit 1
  fi
  echo "${response}"
}

function get_region() {
  local response=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/.$//')
  if [ -z "$response" ]; then
    echo "No region found"
    exit 1
  fi
  echo "${response}"
}

aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "${CONTROLPLANE_ASG_NAME}" \
  --desired-capacity "${CONTROLPLANE_ASG_DESIRED_CAPACITY}" 

mkdir -p ~/cluster-autoscaler/multi-asg
aws s3 cp://${S3_BUCKET}/scripts/addons/cluster-autoscaler.sh /tmp/cluster-autoscaler.sh
chmod +x /tmp/cluster-autoscaler.sh

bash /tmp/cluster-autoscaler.sh \
  "${K8S_CLUSTER_NAME}" "${CLUSTER_AUTO_SCALER_SA}" \
  "${CLUSTER_AUTO_SCALER_SA_NAMESPACE}" \
  "$(get_ann "${CLUSTER_AUTO_SCALER_ROLE_ARN}")"

kubectl apply -f ~/cluster-autoscaler/multi-asg/cluster-autoscaler.yaml

aws s3 cp://${S3_BUCKET}/scripts/addons/aws-load-balancer-controller.sh /tmp/aws-load-balancer-controller.sh
chmod +x /tmp/aws-load-balancer-controller.sh

bash /tmp/aws-load-balancer-controller.sh \
  "${K8S_CLUSTER_NAME}" \
  "${AWS_LOAD_BALANCER_CONTROLLER_SA_NAMESPACE}" \
  "$(get_ann "${AWS_LOAD_BALANCER_CONTROLLER_ROLE_ARN}")"

aws s3 cp s3://${S3_BUCKET}/scripts/addons/external-snapshotter.sh /tmp/external-snapshotter.sh
chmod +x /tmp/external-snapshotter.sh
bash /tmp/external-snapshotter.sh "${EBS_CSI_DRIVER_SA_NAMESPACE}" # TODO: check manifest if it's working and add meaningful snapshot classes 

aws s3 cp s3://${S3_BUCKET}/scripts/addons/aws-ebs-csi-driver.sh /tmp/aws-ebs-csi-driver.sh 
chmod +x /tmp/aws-ebs-csi-driver.sh
bash /tmp/aws-ebs-csi-driver.sh \
  "${K8S_CLUSTER_NAME}" \
  "${EBS_CSI_DRIVER_SA_NAMESPACE}" \
  "$(get_ann "${EBS_CSI_DRIVER_ROLE_ARN}")"

aws s3 cp s3://${S3_BUCKET}/scripts/addons/node-termination-handler.sh /tmp/node-termination-handler.sh
chmod +x /tmp/node-termination-handler.sh
bash /tmp/node-termination-handler.sh \
  "${NTH_NAMESPACE}" \
  "${NTH_SQS_URL}" \
  "0.22.0" \
  "$(get_ann "${NTH_ROLE_ARN}")"
