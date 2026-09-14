variable "digitalocean_token" {
  description = "Short-lived DigitalOcean infrastructure token. Supply with TF_VAR_digitalocean_token; never commit it."
  type        = string
  sensitive   = true
}

variable "spaces_provisioning_access_id" {
  description = "Temporary full-access Spaces key used only to provision buckets. This is not an application runtime key."
  type        = string
  sensitive   = true
}

variable "spaces_provisioning_secret_key" {
  description = "Temporary full-access Spaces secret used only to provision buckets."
  type        = string
  sensitive   = true
}

variable "region" {
  description = "Selected DigitalOcean region after Lebanon latency testing."
  type        = string
  default     = "fra1"

  validation {
    condition     = var.region == "fra1"
    error_message = "The reviewed TerraLeb baseline is fixed to DigitalOcean FRA1. Change only after a recorded region decision and new latency/transfer assessment."
  }
}

variable "droplet_size" {
  description = "Minimum reviewed core size. A smaller size needs a passing staging load and memory report before use."
  type        = string
  default     = "s-4vcpu-8gb"

  validation {
    condition     = contains(["s-4vcpu-8gb", "s-8vcpu-16gb"], var.droplet_size)
    error_message = "Use the reviewed 8 GB minimum or 16 GB scale-up size."
  }
}

variable "droplet_image" {
  description = "Reviewed x86 Ubuntu image slug."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "owner_ssh_public_key" {
  description = "Operator SSH public key. Public key material only; never provide a private key."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|sk-ssh-ed25519@openssh.com) [A-Za-z0-9+/=]+(?: .*)?$", trimspace(var.owner_ssh_public_key)))
    error_message = "Use an Ed25519 SSH public key."
  }
}

variable "operator_ssh_cidrs" {
  description = "Exact public CIDR addresses permitted to reach SSH; never use 0.0.0.0/0."
  type        = list(string)

  validation {
    condition = length(var.operator_ssh_cidrs) > 0 && alltrue([
      for cidr in var.operator_ssh_cidrs : can(cidrnetmask(cidr)) && !contains(["0.0.0.0/0", "::/0"], cidr)
    ])
    error_message = "Supply at least one valid, restricted operator CIDR."
  }
}

variable "bucket_name_prefix" {
  description = "Globally unique lowercase bucket prefix, for example terraleb-prod-<non-secret-suffix>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{8,42}[a-z0-9]$", var.bucket_name_prefix))
    error_message = "Use 10-44 lowercase letters, digits, or hyphens, beginning and ending with a letter or digit."
  }
}

variable "project_description" {
  description = "Non-sensitive DigitalOcean project description."
  type        = string
  default     = "TerraLeb production GIS services"
}
