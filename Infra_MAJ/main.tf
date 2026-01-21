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

# --- RÉSERVATION DES ADRESSES IP (Ports) ---
# On enlève security_group_ids pour laisser OpenStack mettre le 'default' de ton projet
resource "openstack_networking_port_v2" "cp_ports" {
  count      = 3
  name       = "port-k8s-cp${count.index + 1}"
  network_id = data.openstack_networking_network_v2.public.id
}

resource "openstack_networking_port_v2" "worker_ports" {
  count      = 3
  name       = "port-k8s-worker${count.index + 1}"
  network_id = data.openstack_networking_network_v2.public.id
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

  volume {
    volume_id = openstack_blockstorage_volume_v3.cp_data[count.index].id
  }

  user_data = count.index == 0 ? templatefile("${path.module}/cloud-init/cp1.yaml", {
    control_plane_ip = openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]
  }) : templatefile("${path.module}/cloud-init/worker.yaml", {
    control_plane_ip = openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]
  })
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

  volume {
    volume_id = openstack_blockstorage_volume_v3.worker_data[count.index].id
  }

  user_data = templatefile("${path.module}/cloud-init/worker.yaml", {
    control_plane_ip = openstack_networking_port_v2.cp_ports[0].all_fixed_ips[0]
  })
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
