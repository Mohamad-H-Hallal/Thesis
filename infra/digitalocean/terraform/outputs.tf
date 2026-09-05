output "core_reserved_ipv4" {
  description = "Stable IPv4 address to use only after the approved DNS step."
  value       = digitalocean_reserved_ip.core.ip_address
}

output "core_private_ipv4" {
  description = "Private VPC address for controlled internal services."
  value       = digitalocean_droplet.core.ipv4_address_private
}

output "spaces_endpoint" {
  description = "S3-compatible regional endpoint."
  value       = "https://${var.region}.digitaloceanspaces.com"
}

output "bucket_names" {
  description = "Private purpose-separated Space names."
  value       = { for purpose, bucket in digitalocean_spaces_bucket.private : purpose => bucket.name }
}

output "monthly_core_price_reported_by_provider" {
  description = "Provider-reported bundled monthly core price; confirm the plan before apply."
  value       = digitalocean_droplet.core.price_monthly
}
