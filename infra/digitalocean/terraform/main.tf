locals {
  buckets = toset(["uploads", "exports", "offline", "ai", "backups"])
  tags    = ["terraleb", "production", "core"]
}

resource "digitalocean_project" "terraleb" {
  name        = "TerraLeb production"
  description = var.project_description
  purpose     = "Web Application"
  environment = "Production"
  resources = concat(
    [digitalocean_droplet.core.urn, digitalocean_reserved_ip.core.urn],
    [for bucket in digitalocean_spaces_bucket.private : bucket.urn],
  )
}

resource "digitalocean_vpc" "terraleb" {
  name     = "terraleb-prod-vpc"
  region   = var.region
  ip_range = "10.137.0.0/20"
}

resource "digitalocean_ssh_key" "owner" {
  name       = "terraleb-production-owner"
  public_key = trimspace(var.owner_ssh_public_key)
}

resource "digitalocean_droplet" "core" {
  name       = "terraleb-prod-core-1"
  image      = var.droplet_image
  region     = var.region
  size       = var.droplet_size
  vpc_uuid   = digitalocean_vpc.terraleb.id
  ssh_keys   = [digitalocean_ssh_key.owner.fingerprint]
  monitoring = true
  backups    = true
  ipv6       = true
  tags       = local.tags
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    owner_ssh_public_key = trimspace(var.owner_ssh_public_key)
    operator_ssh_cidrs   = var.operator_ssh_cidrs
  })

  backup_policy {
    plan    = "weekly"
    weekday = "SUN"
    hour    = 0
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "digitalocean_reserved_ip" "core" {
  region     = var.region
  droplet_id = digitalocean_droplet.core.id
}

resource "digitalocean_firewall" "core" {
  name        = "terraleb-prod-core"
  droplet_ids = [digitalocean_droplet.core.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.operator_ssh_cidrs
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "icmp"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "53"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "123"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

resource "digitalocean_spaces_bucket" "private" {
  for_each = local.buckets

  name          = "${var.bucket_name_prefix}-${each.key}"
  region        = var.region
  acl           = "private"
  force_destroy = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id                                     = "expire-deleted-versions"
    enabled                                = true
    abort_incomplete_multipart_upload_days = 1

    noncurrent_version_expiration {
      days = 35
    }
  }
}
