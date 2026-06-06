#!/bin/bash

#re-run as root if not already (replaces interactive sudo su root)
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

set -e

#suppress all interactive prompts from apt and needrestart
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

#install software (step 4, 5, 6)
apt-get update && apt-get upgrade -y
apt-get install apt-transport-https tree software-properties-common ca-certificates socat -y
apt-get install vim -y
apt-get install bash-completion -y
snap install helm --classic

#turn off swap (step 7)
swapoff -a

#load modules (step 8)
modprobe overlay
modprobe br_netfilter

#networking (step 9)
cat << EOF | tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

#key for containerd (step 10)
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null

#containerd (step 12)
apt-get update && apt-get install containerd.io -y
containerd config default | tee /etc/containerd/config.toml
sed -e 's/SystemdCgroup = false/SystemdCgroup = true/g' -i /etc/containerd/config.toml
systemctl restart containerd

#kubernetes prep (step 13)
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | gpg --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

#k8s prep (step 14)
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

#update (step 15)
apt-get update

#k8s install (step 16)
apt-get install -y kubeadm=1.34.2-1.1 kubelet=1.34.2-1.1 kubectl=1.34.2-1.1
apt-mark hold kubelet kubeadm kubectl

#add alias (step 17,18)
MASTER_IP_ADDR=$(hostname -i)
echo "$MASTER_IP_ADDR k8scp" >> /etc/hosts
echo "$MASTER_IP_ADDR cp" >> /etc/hosts

#kubeadm file (step 19)
cat << EOF > kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: 1.34.2
controlPlaneEndpoint: "k8scp:6443"
networking:
  podSubnet: 192.168.0.0/16
EOF

#init (step 20)
kubeadm init --config=kubeadm-config.yaml --upload-certs --node-name=cp | tee kubeadm-init.out

#non-root user admin access (step 21)
mkdir -p /home/student/.kube
cp /etc/kubernetes/admin.conf /home/student/.kube/config
chown "$(id -u student):$(id -g student)" /home/student/.kube/config

#apply cilium (step 22)
export KUBECONFIG=/etc/kubernetes/admin.conf
helm repo add cilium https://helm.cilium.io/
helm repo update
helm template cilium cilium/cilium --version 1.19.1 \
--namespace kube-system > cilium-cni.yaml
kubectl apply -f cilium-cni.yaml

#autocomplete (step 23)
echo "source <(kubectl completion bash)" >> /home/student/.bashrc

#alias (my preference)
echo "alias k=kubectl" >> /home/student/.bashrc

#generate join command and publish to project metadata (step 13 automation)
JOIN_CMD=$(kubeadm token create --print-join-command)
gcloud compute project-info add-metadata \
  --metadata="k8s-join-command=${JOIN_CMD} --node-name=worker"
