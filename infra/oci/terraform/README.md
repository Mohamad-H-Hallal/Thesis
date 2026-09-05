# TerraLeb OCI production infrastructure

> Historical provider option only. It was superseded by
> `infra/digitalocean/terraform` on 2026-09-05 before any OCI resource was
> created. Do not apply this module without a new reviewed provider decision.

This module provisions the reviewed baseline in OCI Saudi Arabia West (Jeddah):

- one `VM.Standard.E4.Flex` x86 instance with 4 OCPU/32 GB by default; the lower-cost `VM.Standard.A1.Flex` 6 OCPU/32 GB path remains available only after the complete pinned stack passes ARM64 validation;
- a 300 GB balanced block volume for PostgreSQL and application state;
- five private, versioned Object Storage buckets for uploads, exports, offline packages, AI artifacts, and encrypted backups;
- a VCN, public application subnet, HTTPS/HTTP ingress, and SSH restricted to one operator/VPN CIDR;
- 80% actual-spend and 100% forecast budget alerts.

The module deliberately does not create S3 customer-secret keys, DNS records, TLS certificates, legal retention lifecycle rules, or production deployments. Creating a customer-secret key through Terraform would put the secret in Terraform state. Those actions require owner/provider evidence and are performed interactively through the Phase 8 runbook.

Requirements:

- OpenTofu 1.12.6 (recommended and used for the checked-in validation lock file), or a compatible Terraform 1.8–1.x installation;
- OCI provider 8.27.0 (pinned);
- an OCI configuration profile or short-lived workload identity with permission only in the TerraLeb compartment;
- a reviewed x86_64 image OCID from Jeddah for the current default;
- a trusted SSH source CIDR and an SSH public key.

From Lebanon, HashiCorp's Terraform binary download returned a regional-unavailability response during the 2026-08-26 validation. The open-source OpenTofu 1.12.6 release was therefore downloaded from its official release page, its archive checksum was verified against the official checksum file, and this module passed `tofu fmt`, `tofu init -backend=false`, and `tofu validate`. This is an observed distribution constraint, not a legal conclusion. The module remains Terraform-language compatible.

Run `tofu init`, `tofu fmt -check`, `tofu validate`, and `tofu plan -out=terraleb.tfplan` (or the equivalent `terraform` commands). Review the plan and projected price before any `apply`. Never commit `.terraform`, a plan, state, a populated tfvars file, OCI OCIDs, credentials, or private keys.

The 2026-08-26 architecture gate built and executed the TerraLeb API image on
`linux/arm64`, but the pinned `postgis/postgis:16-3.5-alpine` production digest
has no ARM64 manifest. The module therefore defaults to E4/x86. Do not select
`arm64` merely to reduce cost; first replace or obtain a reviewed multi-arch
PostGIS image and rerun the complete ARM64 stack, migration, backup, and restore
tests. The external production AI image must pass the same gate.

After apply, format and mount the attached data volume only through the documented host bootstrap procedure. Destroying this stack deletes infrastructure and can destroy data; never run `terraform destroy` as a rollback. Application rollback uses the prior immutable images and preserved database/object versions.
