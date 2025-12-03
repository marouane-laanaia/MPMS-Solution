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
}

output "cp1_ip" {
  value = openstack_compute_instance_v2.cp1.access_ip_v4
}

output "worker1_ip" {
  value = openstack_compute_instance_v2.worker1.access_ip_v4
}
