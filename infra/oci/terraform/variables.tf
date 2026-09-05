variable "tenancy_ocid" {
  description = "OCI tenancy OCID. Supply through TF_VAR_tenancy_ocid; do not commit it."
  type        = string
  sensitive   = true
}

variable "compartment_ocid" {
  description = "Dedicated TerraLeb production compartment OCID."
  type        = string
  sensitive   = true
}

variable "region" {
  description = "OCI region identifier. TerraLeb production is fixed to Jeddah."
  type        = string
  default     = "me-jeddah-1"

  validation {
    condition     = var.region == "me-jeddah-1"
    error_message = "TerraLeb production must be deployed in OCI Saudi Arabia West (me-jeddah-1)."
  }
}

variable "availability_domain_index" {
  description = "Zero-based availability-domain index. Jeddah currently has one AD."
  type        = number
  default     = 0
}

variable "project_prefix" {
  description = "Lowercase DNS-compatible prefix used for resources and buckets."
  type        = string
  default     = "terraleb-prod"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,30}[a-z0-9]$", var.project_prefix))
    error_message = "project_prefix must be 4-32 lowercase letters, digits, or hyphens."
  }
}

variable "operator_ssh_cidr" {
  description = "Single trusted operator/VPN CIDR allowed to reach SSH; never use 0.0.0.0/0."
  type        = string

  validation {
    condition = can(cidrnetmask(var.operator_ssh_cidr)) && !contains(
      ["0.0.0.0/0", "::/0"],
      var.operator_ssh_cidr,
    )
    error_message = "operator_ssh_cidr must be a specific trusted CIDR, not the public internet."
  }
}

variable "ssh_public_key" {
  description = "Operator SSH public key. Never supply a private key."
  type        = string
  sensitive   = true
}

variable "compute_image_ocid" {
  description = "Reviewed Ubuntu/Oracle Linux image OCID matching the selected architecture."
  type        = string
  sensitive   = true
}

variable "compute_architecture" {
  description = "amd64 is the reviewed E4 fallback selected after the pinned PostGIS image failed ARM64 validation."
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["arm64", "amd64"], var.compute_architecture)
    error_message = "compute_architecture must be arm64 or amd64."
  }
}

variable "block_volume_size_gb" {
  description = "PostgreSQL/application block volume size."
  type        = number
  default     = 300

  validation {
    condition     = var.block_volume_size_gb >= 300
    error_message = "The production block volume must be at least 300 GB."
  }
}

variable "monthly_budget_usd" {
  description = "Owner-approved monthly OCI budget amount in USD."
  type        = number

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be a positive owner-approved value."
  }
}

variable "budget_alert_email" {
  description = "Verified operational email for OCI budget alerts."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a valid email address."
  }
}

variable "freeform_tags" {
  description = "Non-sensitive cost/allocation tags."
  type        = map(string)
  default = {
    application = "terraleb"
    environment = "production"
    managed_by  = "terraform"
  }
}
