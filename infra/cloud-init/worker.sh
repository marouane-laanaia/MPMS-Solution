#!/bin/bash

# --- 0. Sécurité Anti-Lock APT ---
# Empêche les mises à jour automatiques de bloquer le script
systemctl stop apt-daily.service apt-daily-upgrade.service
systemctl disable apt-daily.service apt-daily-upgrade.service
killall apt apt-get 2>/dev/null
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*
dpkg --configure -a

# --- 1. Résolution locale ---
echo "127.0.0.1 localhost" > /etc/hosts
echo "${control_plane_ip} k8s-api.local" >> /etc/hosts

# --- 2. Préparation Système ---
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg docker.io
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# --- 3. Installation des outils Kubernetes ---
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ ./' | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet=1.30.14-* kubeadm=1.30.14-* kubectl=1.30.14-*
apt-mark hold kubelet kubeadm kubectl

# --- 4. Configuration réseau Kernel & CILIUM PRÉ-REQUIS ---
modprobe overlay
modprobe br_netfilter
echo -e "net.bridge.bridge-nf-call-iptables = 1\nnet.ipv4.ip_forward = 1" > /etc/sysctl.d/k8s.conf
sysctl --system

# PRÉ-REQUIS CILIUM
mkdir -p /sys/fs/bpf /run/cilium/cgroupv2 /var/lib/cilium
mount bpffs /sys/fs/bpf -t bpf
mount -t cgroup2 none /run/cilium/cgroupv2
echo "bpffs /sys/fs/bpf bpf defaults 0 0" >> /etc/fstab
