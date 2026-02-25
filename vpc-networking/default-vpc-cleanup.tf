# ─────────────────────────────────────────────────────────────────────────────
# Default VPC cleanup
#
# Google Cloud creates a "default" VPC with permissive firewall rules in every
# new project. This resource removes it so only explicitly-defined networks
# exist in the project.
#
# Execution order enforced via depends_on:
#   google_project_service.apis
#     → terraform_data.delete_default_vpc
#       → google_compute_network.vpc_global  (see main.tf)
#
# Idempotent: gcloud exits 0 when the network/rules no longer exist, and the
# 2>/dev/null silences the "not found" message on subsequent applies.
# ─────────────────────────────────────────────────────────────────────────────

resource "terraform_data" "delete_default_vpc" {
  # Re-runs only if the project ID changes (i.e., once per project).
  triggers_replace = [var.project_id]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      PROJECT="${var.project_id}"

      echo "Checking for default VPC in project: $PROJECT"

      # Check whether the default network exists at all before proceeding.
      if ! gcloud compute networks describe default \
            --project="$PROJECT" --quiet >/dev/null 2>&1; then
        echo "Default VPC not found — nothing to clean up."
        exit 0
      fi

      echo "Deleting default firewall rules..."
      for rule in $(gcloud compute firewall-rules list \
            --filter="network=default" \
            --format="value(name)" \
            --project="$PROJECT" 2>/dev/null); do
        echo "  Deleting firewall rule: $rule"
        gcloud compute firewall-rules delete "$rule" \
          --project="$PROJECT" --quiet 2>/dev/null || true
      done

      echo "Deleting default VPC network..."
      gcloud compute networks delete default \
        --project="$PROJECT" --quiet

      echo "Default VPC removed successfully."
    EOT
  }

  depends_on = [google_project_service.apis]
}
