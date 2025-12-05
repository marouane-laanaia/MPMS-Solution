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
  name        = "Ubuntu 22.04"
}

data "openstack_compute_keypair_v2" "default" {
  name = "terraform"
}

# --- Délai d'attente fixe pour la stabilisation du Control Plane ---
# 6 minutes pour garantir que kubeadm init et le CNI sont terminés sur CP1.
resource "time_sleep" "wait_for_cp_boot" {
  create_duration = "6m" 
  
  depends_on = [
    openstack_compute_instance_v2.cp[0]
  ]
}

# --- CONTROL PLANES (3 Instances) ---
resource "openstack_blockstorage_volume_v3" "cp_data" {
  count = 3
  name = "k8s-cp${count.index + 1}-data"
  size = 20
}

resource "openstack_compute_instance_v2" "cp" {
  count = 3
  name            = "k8s-cp${count.index + 1}"
  flavor_name     = "m1.small"
  key_pair        = data.openstack_compute_keypair_v2.default.name
  security_groups = ["default"]
  image_id        = data.openstack_images_image_v2.ubuntu.id

  network {
    uuid = data.openstack_networking_network_v2.public.id
  }

  volume {
    volume_id = openstack_blockstorage_volume_v3.cp_data[count.index].id
  }

  user_data = file("${path.module}/cloud-init/cp1.yaml")
}

# Ressource NULL pour joindre CP2 et CP3 (index > 0)
resource "null_resource" "cp_join" {
  count = length(openstack_compute_instance_v2.cp) > 1 ? length(openstack_compute_instance_v2.cp) - 1 : 0
  
  depends_on = [
    time_sleep.wait_for_cp_boot 
  ]
  
  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_ed25519")
    host        = openstack_compute_instance_v2.cp[count.index + 1].access_ip_v4 
    timeout     = "5m"
  }

  # NOUVEAU : Transférer la clé SSH privée (~/.ssh/id_ed25519) sur le noeud CP cible
  provisioner "file" {
    source      = "~/.ssh/id_ed25519"
    destination = "/home/ubuntu/.ssh/id_ed25519"
  }
  
  provisioner "remote-exec" {
    inline = [
      # 1. Rendre la clé non accessible aux autres (important pour SSH)
      "chmod 600 /home/ubuntu/.ssh/id_ed25519",
      # 2. Exécuter la commande SSH imbriquée (utilise la clé nouvellement copiée)
      "ssh -o StrictHostKeyChecking=no -i /home/ubuntu/.ssh/id_ed25519 ubuntu@${openstack_compute_instance_v2.cp[0].access_ip_v4} 'sudo cat /root/join.sh | grep control-plane' | sudo sh",
    ]
  }
}

# --- WORKER NODES (3 Instances) ---
resource "openstack_blockstorage_volume_v3" "worker_data" {
  count = 3
  name = "k8s-worker${count.index + 1}-data"
  size = 20
}

resource "openstack_compute_instance_v2" "worker" {
  count = 3
  name            = "k8s-worker${count.index + 1}"
  flavor_name     = "m1.small"
  key_pair        = data.openstack_compute_keypair_v2.default.name
  security_groups = ["default"]
  image_id        = data.openstack_images_image_v2.ubuntu.id

  network {
    uuid = data.openstack_networking_network_v2.public.id
  }

  volume {
    volume_id = openstack_blockstorage_volume_v3.worker_data[count.index].id
  }

  user_data = file("${path.module}/cloud-init/worker.yaml")
}

# Ressource NULL pour joindre les 3 Workers
resource "null_resource" "worker_join" {
  count = 3

  depends_on = [
    time_sleep.wait_for_cp_boot 
  ]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_ed25519")
    host        = openstack_compute_instance_v2.worker[count.index].access_ip_v4 
    timeout     = "5m"
  }
  
  # NOUVEAU : Transférer la clé SSH privée (~/.ssh/id_ed25519) sur le noeud Worker cible
  provisioner "file" {
    source      = "~/.ssh/id_ed25519"
    destination = "/home/ubuntu/.ssh/id_ed25519"
  }

  provisioner "remote-exec" {
    inline = [
      # 1. Rendre la clé non accessible aux autres (important pour SSH)
      "chmod 600 /home/ubuntu/.ssh/id_ed25519",
      # 2. Exécuter la commande SSH imbriquée (utilise la clé nouvellement copiée)
      "ssh -o StrictHostKeyChecking=no -i /home/ubuntu/.ssh/id_ed25519 ubuntu@${openstack_compute_instance_v2.cp[0].access_ip_v4} 'sudo cat /root/join.sh | grep -v control-plane' | sudo sh",
    ]
  }
}

# --- OUTPUTS ---
output "cp_ips" {
  value = openstack_compute_instance_v2.cp[*].access_ip_v4
}

output "worker_ips" {
  value = openstack_compute_instance_v2.worker[*].access_ip_v4
}
