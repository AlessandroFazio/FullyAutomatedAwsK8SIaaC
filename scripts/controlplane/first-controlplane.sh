#!/bin/bash

# Usage: ./k8s-bootstrap-master-aws-calico-vxlan.sh <cluster-name> <k8s-version> <pod-network-cidr> <cluster-service-cidr> <cluster-default-dns>
K8S_CLUSTER_NAME=$1
K8S_VERSION=$2
K8S_POD_NETWORK_CIDR=$3
K8S_CLUSTER_SERVICE_CIDR=$4
K8S_CLUSTER_DEFAULT_DNS=$5 
K8S_NODES_HOSTNAME_MODE=$6
CONTROLPLANE_ASG_NAME=$7
CONTROLPLANE_ASG_DESIRED_CAPACITY=$8
S3_BUCKET=$9

if [ -z "${K8S_CLUSTER_NAME}" ]; then
  echo "K8S_CLUSTER_NAME is required"
  exit 1
fi

if [ -z "${K8S_VERSION}" ]; then
  echo "K8S_VERSION is required"
  exit 1
fi

if [ -z "${K8S_POD_NETWORK_CIDR}" ]; then
  echo "K8S_POD_NETWORK_CIDR is required"
  exit 1
fi

if [ -z "${K8S_CLUSTER_SERVICE_CIDR}" ]; then
  echo "K8S_CLUSTER_SERVICE_CIDR is required"
  exit 1
fi

if [ -z "${K8S_CLUSTER_DEFAULT_DNS}" ]; then
  echo "K8S_CLUSTER_DEFAULT_DNS is required"
  exit 1
fi

if [ -z "${K8S_NODES_HOSTNAME_MODE}" ]; then
  echo "K8S_NODES_HOSTNAME_MODE is required"
  exit 1
fi

if [ -z "${CONTROLPLANE_ASG_NAME}" ]; then
  echo "CONTROLPLANE_ASG_NAME is required"
  exit 1
fi

if [ -z "${CONTROLPLANE_ASG_DESIRED_CAPACITY}" ]; then
  echo "CONTROLPLANE_ASG_DESIRED_CAPACITY is required"
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
curl kttps://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-x86_64.zip
unzip aws-sam-cli-linux-x86_64.zip -d sam-installation
sudo ./sam-installation/install

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

alias nlb_dns="aws elbv2 describe-load-balancers \
                --query 'LoadBalancers[?Tags[?Key==\`Name\` && Value==\`controlplane-nlb\`]].DNSName'  \
                --output text"

function is_controlplane_nlb_up() {
  if [ -z "$(nlb_dns)" ]; then
    return 1;
  fi
  return 0;
}

timeout=1200
now=$(date +%s)
end_=$((now + timeout))
while ! is_controlplane_nlb_up && [[ "${end_}" -ge "$(date +%s)" ]]; do
  sleep 3;
done

if ! is_controlplane_nlb_up; then
  echo "controlplane-nlb not found after $timeout seconds"
  exit 1
fi

cat <<EOF | tee kubeadm-config.yaml
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
controlPlaneEndpoint: "$(nlb_dns):6443"
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
controllerManager:
  extraArgs:
    cloud-provider: external
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  name: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)
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

aws ssm put-parameter \
  --name "/kubernetes/${K8S_CLUSTER_NAME}/cmd/join/control_plane" \
  --value "${JOIN_CONTROLPLANE_CMD}" \
  --type String \
  --overwrite

aws ssm put-parameter \
  --name "/kubernetes/${K8S_CLUSTER_NAME}/cmd/join/worker" \
  --value "${JOIN_WORKER_CMD}" \
  --type String \
  --overwrite

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "alias k=kubectl" >> .bashrc
echo "alias ka='kubectl apply -f'" >> .bashrc
echo "alias kr='kubectl replace -f'" >> .bashrc
echo "alias kd='kubectl delete -f'" >> .bashrc

wget https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml -O metrics-server.yaml

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

aws s3 cp s3://${S3_BUCKET}/scripts/add-ons/calico-network.sh /tmp/calico.sh
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

while ! is_controlplane_available; do
  sleep 3;
done

kubectl taint nodes --all node-role.kubernetes.io/control-plane=:NoSchedule
kubectl taint nodes --all node-role.kubernetes.io/master=:NoSchedule

helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws

helm repo update

mkdir -p ~/helm/cloud-controller/aws/values/

cat <<EOF | tee ~/helm/cloud-controller/aws/values/values.yaml
args:
  - --v=2
  - --cloud-provider=aws
  - --configure-cloud-routes=false
EOF

helm upgrade \
  --install aws-cloud-controller-manager aws-cloud-controller-manager/aws-cloud-controller-manager \
  -f ~/helm/cloud-controller/aws/values/values.yaml

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

KUBECONFIG_OBJECT="/files/config/kubeconfig"
aws s3 cp ~/.kube/config s3://${S3_BUCKET}/${KUBECONFIG_OBJECT}

REGION=$(get_region)
aws s3 cp s3://${S3_BUCKET}/scripts/k8s-drainer-bootstrap.sh /tmp/k8s-drainer-bootstrap.sh
chmod +x /tmp/k8s-drainer-bootstrap.sh

for asg_name in $(retrieve_asg_names); do
  bash /tmp/k8s-drainer-bootstrap.sh \
    "${K8S_CLUSTER_NAME}" \
    "${asg_name}" \
    "${S3_BUCKET}" \
    "${KUBECONFIG_OBJECT}" \
    "${REGION}"
done

aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "${CONTROLPLANE_ASG_NAME}" \
  --desired-capacity "${CONTROLPLANE_ASG_DESIRED_CAPACITY}" 

mkdir -p ~/cluster-autoscaler/multi-asg
aws s3 cp://${S3_BUCKET}/scripts/add-ons/cluster-autoscaler.sh /tmp/cluster-autoscaler.sh
chmod +x /tmp/cluster-autoscaler.sh
bash /tmp/cluster-autoscaler.sh "${K8S_CLUSTER_NAME}"
kubectl apply -f ~/cluster-autoscaler/multi-asg/cluster-autoscaler.yaml