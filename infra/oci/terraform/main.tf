locals {
  is_arm64          = var.compute_architecture == "arm64"
  compute_shape     = local.is_arm64 ? "VM.Standard.A1.Flex" : "VM.Standard.E4.Flex"
  compute_ocpus     = local.is_arm64 ? 6 : 4
  compute_memory_gb = 32
  object_buckets = {
    uploads = "${var.project_prefix}-uploads"
    exports = "${var.project_prefix}-exports"
    offline = "${var.project_prefix}-offline"
    ai      = "${var.project_prefix}-ai"
    backups = "${var.project_prefix}-backups"
  }
}

data "oci_identity_availability_domains" "available" {
  compartment_id = var.tenancy_ocid
}

data "oci_objectstorage_namespace" "current" {
  compartment_id = var.tenancy_ocid
}

resource "oci_core_vcn" "terraleb" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.42.0.0/16"]
  display_name   = "${var.project_prefix}-vcn"
  dns_label      = "terraleb"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_internet_gateway" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.terraleb.id
  display_name   = "${var.project_prefix}-internet-gateway"
  enabled        = true
  freeform_tags  = var.freeform_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.terraleb.id
  display_name   = "${var.project_prefix}-public-routes"
  freeform_tags  = var.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.public.id
  }
}

resource "oci_core_network_security_group" "app" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.terraleb.id
  display_name   = "${var.project_prefix}-app-nsg"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group_security_rule" "https" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "http_bootstrap" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "ssh" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.operator_ssh_cidr
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "egress" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.terraleb.id
  cidr_block                 = "10.42.10.0/24"
  display_name               = "${var.project_prefix}-public-subnet"
  dns_label                  = "app"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  freeform_tags              = var.freeform_tags
}

resource "oci_core_instance" "app" {
  availability_domain = data.oci_identity_availability_domains.available.availability_domains[var.availability_domain_index].name
  compartment_id      = var.compartment_ocid
  display_name        = "${var.project_prefix}-app"
  shape               = local.compute_shape
  freeform_tags       = var.freeform_tags

  shape_config {
    ocpus         = local.compute_ocpus
    memory_in_gbs = local.compute_memory_gb
  }

  create_vnic_details {
    assign_public_ip = true
    display_name     = "${var.project_prefix}-primary-vnic"
    hostname_label   = "collector"
    nsg_ids          = [oci_core_network_security_group.app.id]
    subnet_id        = oci_core_subnet.public.id
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }

  source_details {
    source_id               = var.compute_image_ocid
    source_type             = "image"
    boot_volume_size_in_gbs = 50
    boot_volume_vpus_per_gb = 10
  }

  lifecycle {
    precondition {
      condition     = local.is_arm64 ? local.compute_shape == "VM.Standard.A1.Flex" : local.compute_shape == "VM.Standard.E4.Flex"
      error_message = "Compute architecture and shape selection are inconsistent."
    }
  }
}

resource "oci_core_volume" "data" {
  availability_domain = oci_core_instance.app.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.project_prefix}-data"
  size_in_gbs         = var.block_volume_size_gb
  vpus_per_gb         = 10
  freeform_tags       = var.freeform_tags
}

resource "oci_core_volume_attachment" "data" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.app.id
  volume_id       = oci_core_volume.data.id
  display_name    = "${var.project_prefix}-data-attachment"
}

resource "oci_objectstorage_bucket" "private" {
  for_each = local.object_buckets

  compartment_id        = var.compartment_ocid
  namespace             = data.oci_objectstorage_namespace.current.namespace
  name                  = each.value
  access_type           = "NoPublicAccess"
  object_events_enabled = true
  storage_tier          = "Standard"
  versioning            = "Enabled"
  freeform_tags         = merge(var.freeform_tags, { purpose = each.key })
}

resource "oci_budget_budget" "monthly" {
  amount         = var.monthly_budget_usd
  compartment_id = var.tenancy_ocid
  description    = "TerraLeb production monthly OCI budget"
  display_name   = "${var.project_prefix}-monthly-budget"
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.compartment_ocid]
  freeform_tags  = var.freeform_tags
}

resource "oci_budget_alert_rule" "actual" {
  budget_id      = oci_budget_budget.monthly.id
  description    = "Notify operations when actual TerraLeb spend reaches 80 percent"
  display_name   = "${var.project_prefix}-actual-80"
  recipients     = var.budget_alert_email
  threshold      = 80
  threshold_type = "PERCENTAGE"
  type           = "ACTUAL"
}

resource "oci_budget_alert_rule" "forecast" {
  budget_id      = oci_budget_budget.monthly.id
  description    = "Notify operations when forecast TerraLeb spend reaches 100 percent"
  display_name   = "${var.project_prefix}-forecast-100"
  recipients     = var.budget_alert_email
  threshold      = 100
  threshold_type = "PERCENTAGE"
  type           = "FORECAST"
}
