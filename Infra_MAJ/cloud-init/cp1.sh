#!/bin/bash

# --- 0. Sécurité Anti-Lock APT ---
systemctl stop apt-daily.service apt-daily-upgrade.service
systemctl disable apt-daily.service apt-daily-upgrade.service
killall apt apt-get 2>/dev/null
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*
dpkg --configure -a

# --- 1. Préparation Système ---
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

echo "127.0.0.1 localhost" > /etc/hosts
echo "${control_plane_ip} k8s-api.local" >> /etc/hosts

swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# --- 2. Installation Docker/Containerd ---
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl restart containerd

# --- 3. Installation Kubernetes & Pré-requis Cilium ---
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ ./' | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet=1.30.14-* kubeadm=1.30.14-* kubectl=1.30.14-*
apt-mark hold kubelet kubeadm kubectl

echo -e "overlay\nbr_netfilter" > /etc/modules-load.d/k8s.conf
modprobe overlay && modprobe br_netfilter
echo -e "net.bridge.bridge-nf-call-ip6tables = 1\nnet.bridge.bridge-nf-call-iptables = 1\nnet.ipv4.ip_forward = 1" > /etc/sysctl.d/k8s.conf
sysctl --system

mkdir -p /sys/fs/bpf /run/cilium/cgroupv2 /var/lib/cilium
mount bpffs /sys/fs/bpf -t bpf
mount -t cgroup2 none /run/cilium/cgroupv2
echo "bpffs /sys/fs/bpf bpf defaults 0 0" >> /etc/fstab

systemctl enable --now kubelet

# --- 4. Initialisation du Cluster ---
kubeadm init --kubernetes-version=v1.30.14 \
  --control-plane-endpoint "k8s-api.local:6443" \
  --pod-network-cidr=10.244.0.0/16 \
  --upload-certs \
  --ignore-preflight-errors=all

mkdir -p /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config
mkdir -p /home/ubuntu/.kube && cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

# --- 5. Génération des scripts de jointure ---
CERT_KEY=$(kubeadm init phase upload-certs --upload-certs | tail -1)
JOIN_CMD=$(kubeadm token create --print-join-command)

echo "$JOIN_CMD" > /root/join-worker.sh
echo "$JOIN_CMD --control-plane --certificate-key $CERT_KEY" > /root/join-cp.sh
chmod +x /root/join-worker.sh /root/join-cp.sh

# --- 6. Réseau (Cilium) & Addons ---
export KUBECONFIG=/etc/kubernetes/admin.conf
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
tar -xzf cilium-linux-amd64.tar.gz -C /usr/local/bin
rm cilium-linux-amd64.tar.gz

cilium install --version 1.16.5 \
  --set ipam.mode=cluster-pool \
  --set operator.replicas=1 \
  --set tunnel-protocol=vxlan \
  --set ipv4.enabled=true \
  --set bpf.masquerade=true \
  --set nodePort.enabled=true

kubectl rollout status deployment cilium-operator -n kube-system --timeout=120s
kubectl get configmap kube-proxy -n kube-system -o yaml | sed 's/strictARP: false/strictARP: true/' | kubectl apply -f -
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml
