terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.53.0"
    }
  }
}

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

resource "openstack_blockstorage_volume_v3" "cp_data" {
  name = "k8s-cp1-data"
  size = 20
}

resource "openstack_blockstorage_volume_v3" "worker_data" {
  name = "k8s-worker1-data"
  size = 20
}

resource "openstack_compute_instance_v2" "cp1" {
  name            = "k8s-cp1"
  flavor_name     = "m1.medium"
  key_pair        = data.openstack_compute_keypair_v2.default.name
  security_groups = ["default"]
  image_id        = data.openstack_images_image_v2.ubuntu.id

  network {
    uuid = data.openstack_networking_network_v2.public.id
  }

  # Volume DATA attaché (syntaxe correcte)
  volume {
    volume_id = openstack_blockstorage_volume_v3.cp_data.id
  }

  user_data = file("${path.module}/cloud-init/cp1.yaml")
}

resource "openstack_compute_instance_v2" "worker1" {
  name            = "k8s-worker1"
  flavor_name     = "m1.medium"
  key_pair        = data.openstack_compute_keypair_v2.default.name
  security_groups = ["default"]
  image_id        = data.openstack_images_image_v2.ubuntu.id

  network {
    uuid = data.openstack_networking_network_v2.public.id
  }

  # Volume DATA attaché (syntaxe correcte)
  volume {
    volume_id = openstack_blockstorage_volume_v3.worker_data.id
  }

  user_data = file("${path.module}/cloud-init/worker.yaml")

  # ✅ CORRECTION: depends_on doit être ici, dans le corps de la ressource.
  # Ceci assure que CP1 est créé avant de tenter de provisionner Worker1.
  depends_on = [
    openstack_compute_instance_v2.cp1
  ]

  provisioner "remote-exec" {
    inline = [
      # 1. Attendre un court instant pour s'assurer que CP1 a généré le token
      "sleep 60", 
      
      # 2. Récupérer et exécuter le join script. Le chemin de la clé privée est corrigé ici.
      "ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@${openstack_compute_instance_v2.cp1.access_ip_v4} 'cat /root/join.sh' | sudo sh",
    ]

    connection {
      # Connexion établie PAR TERRAFORM VERS LE WORKER
      type        = "ssh"
      user        = "ubuntu" # Utilisateur par défaut de l'image Ubuntu
      private_key = file("~/.ssh/id_ed25519") # Chemin vers votre clé SSH privée
      host        = self.access_ip_v4 # IP publique/flottante du Worker
      timeout     = "5m"
    }
    
    # Le depends_on n'est plus nécessaire ici
  }
}

output "cp1_ip" {
  value = openstack_compute_instance_v2.cp1.access_ip_v4
}

output "worker1_ip" {
  value = openstack_compute_instance_v2.worker1.access_ip_v4
}
