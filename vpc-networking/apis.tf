# ─────────────────────────────────────────────────────────────────────────────
# Project API enablement
#
# All compute and GKE-adjacent APIs must be active before any resources are
# created. disable_on_destroy = false prevents Terraform from turning off
# APIs that other tools or services in the project may also rely on.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  required_apis = [
    "compute.googleapis.com",           # VPC, subnets, Cloud Router, Cloud NAT
    "container.googleapis.com",         # GKE
    "cloudresourcemanager.googleapis.com", # Required by provider & IAM lookups
    "iam.googleapis.com",               # Service accounts & IAM bindings
    "logging.googleapis.com",           # VPC Flow Logs, Cloud NAT logs
    "monitoring.googleapis.com",        # GKE system metrics
    "dns.googleapis.com",               # Cloud DNS (used by GKE for internal DNS)
    "servicenetworking.googleapis.com", # Private Service Connect / PSA
    "networkmanagement.googleapis.com", # Network Intelligence Center (optional but recommended)
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)

  project                    = var.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}
