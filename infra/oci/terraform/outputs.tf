output "public_ip" {
  description = "Public IP to place behind the approved production DNS record."
  value       = oci_core_instance.app.public_ip
}

output "compute_shape" {
  value = {
    architecture = var.compute_architecture
    shape        = local.compute_shape
    ocpus        = local.compute_ocpus
    memory_gb    = local.compute_memory_gb
  }
}

output "object_storage_namespace" {
  value = data.oci_objectstorage_namespace.current.namespace
}

output "s3_compatibility_endpoint" {
  value = "https://${data.oci_objectstorage_namespace.current.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}

output "private_bucket_names" {
  value = { for purpose, bucket in oci_objectstorage_bucket.private : purpose => bucket.name }
}

output "data_volume_id" {
  value = oci_core_volume.data.id
}
