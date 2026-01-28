terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.53.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9.1"
    }
  }
}

# --- Data Sources ---
data "openstack_networking_network_v2" "public" {
  name = "public"
}

data "openstack_images_image_v2" "ubuntu" {
  most_recent = true
  name        = "Ubuntu-22.04"
}

data "openstack_compute_keypair_v2" "default" {
  name = "terraform"
}



# --- SECURITY GROUPS ---

resource "openstack_networking_secgroup_v2" "k8s_secgroup" {
  name        = "k8s-sg"
  description = "Security group for Kubernetes cluster"
}

resource "openstack_networking_secgroup_rule_v2" "ssh_rule" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

resource "openstack_networking_secgroup_rule_v2" "k8s_api_rule" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

resource "openstack_networking_secgroup_rule_v2" "internal_rule" {
  description       = "Allow all internal traffic (Cilium VXLAN 8472/UDP, Etcd 2379-2380/TCP, Kubelet 10250/TCP, etc.)"
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_group_id   = openstack_networking_secgroup_v2.k8s_secgroup.id
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

resource "openstack_networking_secgroup_rule_v2" "nodeport_rule" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30000
  port_range_max    = 32767
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

resource "openstack_networking_secgroup_rule_v2" "icmp_rule" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Accès Grafana (port 30300)
resource "openstack_networking_secgroup_rule_v2" "grafana_rule" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30300
  port_range_max    = 30300
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Accès Prometheus (port 30090)
resource "openstack_networking_secgroup_rule_v2" "prometheus_rule" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30090
  port_range_max    = 30090
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Accès Alertmanager (port 30093)
resource "openstack_networking_secgroup_rule_v2" "alertmanager_rule" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30093
  port_range_max    = 30093
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}




# --- RÉSERVATION DES ADRESSES IP (Ports) ---
# Utilisation des ports pour IP fixes
resource "openstack_networking_port_v2" "cp_ports" {
  count              = 3
  name               = "port-k8s-cp${count.index + 1}"
  network_id         = data.openstack_networking_network_v2.public.id
  security_group_ids = [openstack_networking_secgroup_v2.k8s_secgroup.id]
}

resource "openstack_networking_port_v2" "worker_ports" {
  count              = 3
  name               = "port-k8s-worker${count.index + 1}"
  network_id         = data.openstack_networking_network_v2.public.id
  security_group_ids = [openstack_networking_secgroup_v2.k8s_secgroup.id]
}

# --- Délai d'attente pour le Control Plane 1 ---
resource "time_sleep" "wait_for_cp_boot" {
  create_duration = "10m"
  depends_on      = [openstack_compute_instance_v2.cp[0]]
}

# --- VOLUMES (8Go pour économiser ton quota) ---
resource "openstack_blockstorage_volume_v3" "cp_data" {
  count = 3
  name  = "k8s-cp${count.index + 1}-data"
  size  = 8
}

resource "openstack_blockstorage_volume_v3" "worker_data" {
  count = 3
  name  = "k8s-worker${count.index + 1}-data"
  size  = 8
}



# --- CONTROL PLANES ---
resource "openstack_compute_instance_v2" "cp" {
  count       = 3
  name        = "k8s-cp${count.index + 1}"
  flavor_name = "m1.small"
  key_pair    = data.openstack_compute_keypair_v2.default.name
  image_id    = data.openstack_images_image_v2.ubuntu.id



  network {
    port = openstack_networking_port_v2.cp_ports[count.index].id
  }


  user_data = count.index == 0 ? templatefile("${path.module}/cloud-init/cp1.sh", {
    control_plane_ip = openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]
    }) : templatefile("${path.module}/cloud-init/worker.sh", {
    control_plane_ip = openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]
  })
}

resource "openstack_compute_volume_attach_v2" "cp_volume_attach" {
  count       = 3
  instance_id = openstack_compute_instance_v2.cp[count.index].id
  volume_id   = openstack_blockstorage_volume_v3.cp_data[count.index].id
}

# --- WORKER NODES ---
resource "openstack_compute_instance_v2" "worker" {
  count       = 3
  name        = "k8s-worker${count.index + 1}"
  flavor_name = "m1.small"
  key_pair    = data.openstack_compute_keypair_v2.default.name
  image_id    = data.openstack_images_image_v2.ubuntu.id



  network {
    port = openstack_networking_port_v2.worker_ports[count.index].id
  }


  user_data = templatefile("${path.module}/cloud-init/worker.sh", {
    control_plane_ip = openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]
  })
}

resource "openstack_compute_volume_attach_v2" "worker_volume_attach" {
  count       = 3
  instance_id = openstack_compute_instance_v2.worker[count.index].id
  volume_id   = openstack_blockstorage_volume_v3.worker_data[count.index].id
}

# --- JOINTURE CP (SSH via IP du port) ---
resource "null_resource" "cp_join" {
  count      = 2
  depends_on = [time_sleep.wait_for_cp_boot]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_ed25519")
    host        = openstack_networking_port_v2.cp_ports[count.index + 1].all_fixed_ips[0]
  }

  provisioner "file" {
    source      = "~/.ssh/id_ed25519"
    destination = "/home/ubuntu/.ssh/id_ed25519"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 /home/ubuntu/.ssh/id_ed25519",
      # On attend que le fichier soit prêt sur CP1 avant de tenter le cat
      "while ! ssh -i /home/ubuntu/.ssh/id_ed25519 -o StrictHostKeyChecking=no ubuntu@${openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]} 'sudo test -f /root/join-cp.sh'; do echo 'En attente du script sur CP1...'; sleep 10; done",
      # On récupère, on modifie pour le CPU, et on exécute
      "ssh -i /home/ubuntu/.ssh/id_ed25519 -o StrictHostKeyChecking=no ubuntu@${openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]} 'sudo cat /root/join-cp.sh' | sed 's/kubeadm join/kubeadm join --ignore-preflight-errors=NumCPU/' | sudo bash"
    ]
  }
}
# --- JOINTURE WORKERS ---
resource "null_resource" "worker_join" {
  count      = 3
  depends_on = [time_sleep.wait_for_cp_boot]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_ed25519")
    host        = openstack_networking_port_v2.worker_ports[count.index].all_fixed_ips[0]
  }

  provisioner "file" {
    source      = "~/.ssh/id_ed25519"
    destination = "/home/ubuntu/.ssh/id_ed25519"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 /home/ubuntu/.ssh/id_ed25519",
      "ssh -o StrictHostKeyChecking=no -i /home/ubuntu/.ssh/id_ed25519 ubuntu@${openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]} 'sudo cat /root/join-worker.sh' | sudo bash -x",
    ]
  }
}


# --- DÉPLOIEMENT PROMETHEUS + GRAFANA ---
resource "null_resource" "deploy_monitoring" {
  depends_on = [
    time_sleep.wait_for_cp_boot,
    null_resource.worker_join
  ]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_ed25519")
    host        = openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]
  }

  provisioner "remote-exec" {
    inline = [
      # Attendre que le cluster soit stable
      "echo 'Attente de la stabilité du cluster...'",
      "sleep 30",

      # Installation de Helm si pas déjà fait
      "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true",

      # Création du namespace monitoring
      "kubectl create namespace monitoring || true",

      # Ajout du repo Prometheus Community
      "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts",
      "helm repo update",

      # Installation de kube-prometheus-stack
      "helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \\",
      "  --namespace monitoring \\",
      "  --set prometheus.prometheusSpec.retention=15d \\",
      "  --set prometheus.service.type=NodePort \\",
      "  --set prometheus.service.nodePort=30090 \\",
      "  --set grafana.service.type=NodePort \\",
      "  --set grafana.service.nodePort=30300 \\",
      "  --set grafana.adminPassword=admin123 \\",
      "  --set alertmanager.service.type=NodePort \\",
      "  --set alertmanager.service.nodePort=30093 \\",
      "  --timeout 10m \\",
      "  --wait",

      # Afficher les infos de connexion
      "echo ''",
      "echo '========================================='",
      "echo 'MONITORING STACK DEPLOYED'",
      "echo '========================================='",
      "echo 'Grafana URL: http://${openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]}:30300'",
      "echo 'Grafana User: admin'",
      "echo 'Grafana Password: admin123'",
      "echo ''",
      "echo 'Prometheus URL: http://${openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]}:30090'",
      "echo ''",
      "echo 'Alertmanager URL: http://${openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]}:30093'",
      "echo '========================================='",

      # Sauvegarder les infos
      "cat > /home/ubuntu/monitoring-info.txt <<EOF",
      "Grafana URL: http://${openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]}:30300",
      "Grafana User: admin",
      "Grafana Password: admin123",
      "echo ''",
      "Prometheus URL: http://${openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]}:30090",
      "Alertmanager URL: http://${openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]}:30093",
      "EOF"
    ]
  }
}


# --- OUTPUTS ---
output "grafana_url" {
  value       = "http://${openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]}:30300"
  description = "Grafana URL (admin/admin123)"
}

output "prometheus_url" {
  value       = "http://${openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]}:30090"
  description = "Prometheus URL"
}

output "cp1_ip" {
  value       = openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]
  description = "Control Plane 1 IP"
}
