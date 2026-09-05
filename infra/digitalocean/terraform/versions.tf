terraform {
  required_version = ">= 1.8.0"

  # Live initialization uses a pre-created private, versioned FRA1 Space with
  # partial backend configuration and AWS_SSE_CUSTOMER_KEY. Credentials and
  # key material are supplied only through environment variables.
  backend "s3" {}

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.100.0"
    }
  }
}

provider "digitalocean" {
  token             = var.digitalocean_token
  spaces_access_id  = var.spaces_provisioning_access_id
  spaces_secret_key = var.spaces_provisioning_secret_key
}
