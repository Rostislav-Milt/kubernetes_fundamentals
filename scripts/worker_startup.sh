#!/bin/bash

#re-run as root if not already (replaces interactive sudo su root)
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi
set -e
#suppress all interactive prompts from apt and needrestart
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

#install software (step 3, 4)
apt-get update && apt-get upgrade -y
apt-get install apt-transport-https software-properties-common ca-certificates tree socat -y
swapoff -a
modprobe overlay
modprobe br_netfilter
cat << EOF | tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update &&  apt-get install containerd.io -y
containerd config default | tee /etc/containerd/config.toml
sed -e 's/SystemdCgroup = false/SystemdCgroup = true/g' -i /etc/containerd/config.toml
systemctl restart containerd

#get gpg keys (step 5)
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

#add k8s repo (step 6)
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

#install k8s (step 7, 8)
apt-get update
apt-get install -y kubeadm=1.34.2-1.1 kubelet=1.34.2-1.1 kubectl=1.34.2-1.1

#make sure version is held (step 9)
apt-mark hold kubeadm kubelet kubectl

#add master IP to hosts (step 10,11,12)
MASTER_IP=$(curl -sf -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/master-ip)
echo "$MASTER_IP k8scp" >> /etc/hosts
echo "$MASTER_IP cp" >> /etc/hosts

#wait for master to publish join command, then join (step 13)
until JOIN_CMD=$(gcloud compute project-info describe \
  --format="value(commonInstanceMetadata.items[k8s-join-command])" 2>/dev/null) \
  && echo "$JOIN_CMD" | grep -q "kubeadm join"; do
  sleep 15
done

eval "$JOIN_CMD"

#alias (my preference)
echo "alias k=kubectl" >> /home/student/.bashrc
source /home/student/.bashrc