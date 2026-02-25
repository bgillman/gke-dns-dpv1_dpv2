#!/bin/bash
# ------------------------------------------------------------------------------
# Phase 3b — Add A records to the svc.internal private zone
#
# Run this AFTER the ILB services in both clusters have been applied AND
# their external IPs have been assigned (status shows an IP, not <pending>).
#
# How to get the ILB IPs:
#
#   Terminal 1 (dpv1 context):
#     kubectl get svc backend-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
#
#   Terminal 2 (dpv2 context):
#     kubectl get svc backend-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
#
# Then fill in the two variables below and run this script.
# ------------------------------------------------------------------------------

set -e

PROJECT_ID="gillman-gke-dns"
ZONE_NAME="svc-internal"

# ── FILL THESE IN before running ─────────────────────────────────────────────
DPV1_ILB_IP="10.0.0.11"   # e.g. "10.0.0.5"  — from central-vpc-subnet-01 (10.0.0.0/20)
DPV2_ILB_IP="10.1.0.6"   # e.g. "10.1.0.5"  — from west-vpc-subnet-01    (10.1.0.0/20)
# ─────────────────────────────────────────────────────────────────────────────

if [ -z "$DPV1_ILB_IP" ] || [ -z "$DPV2_ILB_IP" ]; then
  echo "ERROR: Set DPV1_ILB_IP and DPV2_ILB_IP before running this script."
  exit 1
fi

echo "[INFO] Adding A record: backend-central.svc.internal -> $DPV1_ILB_IP"
gcloud dns record-sets create backend-central.svc.internal. \
  --project="$PROJECT_ID" \
  --zone="$ZONE_NAME" \
  --type=A \
  --ttl=300 \
  --rrdatas="$DPV1_ILB_IP"

echo "[INFO] Adding A record: backend-west.svc.internal -> $DPV2_ILB_IP"
gcloud dns record-sets create backend-west.svc.internal. \
  --project="$PROJECT_ID" \
  --zone="$ZONE_NAME" \
  --type=A \
  --ttl=300 \
  --rrdatas="$DPV2_ILB_IP"

echo ""
echo "[SUCCESS] DNS records created."
echo ""
echo "Verify all records in zone:"
echo "  gcloud dns record-sets list --zone=$ZONE_NAME --project=$PROJECT_ID"
