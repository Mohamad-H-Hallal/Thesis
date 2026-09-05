terraform {
  required_version = ">= 1.8.0, < 2.0.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "8.27.0"
    }
  }
}

provider "oci" {
  region = var.region
}
