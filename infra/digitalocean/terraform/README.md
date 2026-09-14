# TerraLeb DigitalOcean production infrastructure

This is the active low-cost production baseline. It creates one x86 core Droplet in Frankfurt (`fra1`), a private VPC, a restricted cloud firewall, a stable assigned Reserved IP, weekly Droplet backups, provider monitoring, and five private versioned Spaces buckets. It does not create DNS, publish legal documents, deploy application secrets, or provision AI compute.

The reviewed minimum is `s-4vcpu-8gb`. The earlier proposed 1 vCPU/2 GB host is explicitly a development/demo option and is not accepted for production: it cannot safely fit PostgreSQL/PostGIS, ClamAV, Valkey, the API, workload worker, Nginx, and monitoring. AI remains enabled in the product but must run on separately approved on-demand compute after its image and least-privilege data path pass the existing AI gate.

DigitalOcean has no Middle East datacenter. `fra1` is selected as the initial candidate, not as proven Lebanon performance. Live latency, DPA/international-transfer evidence, provider terms, and a reviewed plan are mandatory before apply.

## Safe validation

Use Terraform/OpenTofu 1.8 or newer. Keep the DigitalOcean token and temporary Spaces provisioning key in a local secure credential store and expose them only as `TF_VAR_digitalocean_token`, `TF_VAR_spaces_provisioning_access_id`, and `TF_VAR_spaces_provisioning_secret_key` for the command. Never commit them, a populated `terraform.tfvars`, plan, or state.

1. Before a live initialization, create one private versioned FRA1 Space dedicated to Terraform state and one state-only Spaces key. Configure 35-day non-current-version expiry. This bootstrap bucket is separate from the five application buckets.
2. Copy `terraform.tfvars.example` to ignored `terraform.tfvars` and enter only the public SSH key, restricted operator CIDR, and non-secret unique bucket prefix.
3. Export the state-only key through `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, and export its 32-byte base64 SSE-C key through `AWS_SSE_CUSTOMER_KEY`. Never put these values in `-backend-config`, because Terraform can copy backend arguments into `.terraform` and plans.
4. Copy `backend.hcl.example` to ignored `backend.hcl`, replace only the state Space name, and initialize with `tofu init -backend-config=backend.hcl`. The file contains no credentials or encryption key. Confirm Spaces supports the state-lock conditional-write operation during the first live plan; if it does not, use a reviewed external lock process and never run concurrent plans.
5. Run `tofu fmt -check` and `tofu validate`.
6. Run `tofu plan -out=terraleb.tfplan`.
7. Review every resource and the DigitalOcean checkout prices. Do not apply until the owner explicitly approves the displayed recurring cost and international-hosting decision.

After bucket creation, revoke the provisioning key. Create two scoped runtime keys: one limited to the four application buckets and one limited to the backup bucket. Store them only in the Docker secret files named by `.env.prod.example`. Do not enable a CDN or public file listing.

HashiCorp documents alternate S3 backends as best-effort rather than guaranteed compatibility. The live state read/write/version/lock/unlock/recovery test is therefore mandatory: <https://developer.hashicorp.com/terraform/language/backend/s3>.

## Cost boundary

At the public rates reviewed on 2026-09-05, the selected 8 GB Basic Droplet is USD 48/month, weekly basic backups add USD 9.60/month, and Standard Spaces starts at USD 5/month for 250 GiB. The initial infrastructure subtotal is therefore about USD 62.60/month or USD 751.20/year before tax, domain, email/SMS, ArcGIS/GEE usage, registry, counsel, overages, and separately running AI compute. An assigned Reserved IP and basic monitoring do not add a charge. Provider checkout remains authoritative.

## Rollback

Application rollback uses immutable images and the documented database restore process. Reassigning the Reserved IP can move traffic to a replacement Droplet. The core Droplet has Terraform `prevent_destroy`; removal requires an explicit reviewed code change. Buckets use `force_destroy = false`, so infrastructure cleanup cannot silently delete retained objects.
