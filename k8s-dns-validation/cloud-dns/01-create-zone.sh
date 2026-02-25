#!/bin/bash
# ------------------------------------------------------------------------------
# Phase 3a — Create the Cloud DNS private zone
#
# Run this BEFORE the ILB services are applied. The zone must exist before
# records can be added. The --networks flag scopes this zone to vpc-global,
# making it resolvable by all resources in the VPC including pods in both
# clusters (once kube-dns on dpv1 is configured to forward — see Phase 4).
# ------------------------------------------------------------------------------

set -e

PROJECT_ID="gillman-gke-dns"
VPC_NETWORK="vpc-global"
ZONE_NAME="svc-internal"
DNS_NAME="svc.internal."

echo "[INFO] Creating Cloud DNS private zone: $ZONE_NAME ($DNS_NAME)"

gcloud dns managed-zones create "$ZONE_NAME" \
  --project="$PROJECT_ID" \
  --dns-name="$DNS_NAME" \
  --description="Cross-cluster service discovery — backend endpoints for gke-std-dpv1 and gke-std-dpv2" \
  --visibility=private \
  --networks="$VPC_NETWORK"

echo "[SUCCESS] Zone '$ZONE_NAME' created."
echo ""
echo "Verify:"
echo "  gcloud dns managed-zones describe $ZONE_NAME --project=$PROJECT_ID"
