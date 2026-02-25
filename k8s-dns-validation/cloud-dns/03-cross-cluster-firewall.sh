#!/bin/bash
# ------------------------------------------------------------------------------
# Cross-cluster firewall rules
#
# Problem: GKE automatically creates firewall rules for Internal LB traffic,
# but those rules only allow sources from within the SAME cluster's node and
# pod CIDRs. Traffic sourced from another cluster's pod CIDR arrives at the
# destination nodes with no matching allow rule and is silently dropped.
#
# Fix: Two ingress rules on vpc-global — one per direction — allowing each
# cluster's pod CIDR to reach the other cluster's GKE nodes on port 80.
#
# Node tags: both clusters were created with --tags="gke-cluster,private-cluster"
# so we target those tags on the destination side.
#
# Source CIDRs:
#   dpv1 pods: 10.4.0.0/14  (central-pods secondary range)
#   dpv2 pods: 10.8.0.0/14  (west-pods secondary range)
# ------------------------------------------------------------------------------

set -e

PROJECT_ID="gillman-gke-dns"
NETWORK="vpc-global"

echo "[INFO] Creating firewall rule: allow dpv1 pods -> dpv2 nodes (port 80)"
gcloud compute firewall-rules create allow-dpv1-pods-to-dpv2-ilb \
  --project="$PROJECT_ID" \
  --network="$NETWORK" \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:80 \
  --source-ranges="10.4.0.0/14" \
  --target-tags="gke-cluster,private-cluster" \
  --description="Allow dpv1 pod CIDR to reach dpv2 ILB backend nodes on port 80"

echo "[INFO] Creating firewall rule: allow dpv2 pods -> dpv1 nodes (port 80)"
gcloud compute firewall-rules create allow-dpv2-pods-to-dpv1-ilb \
  --project="$PROJECT_ID" \
  --network="$NETWORK" \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:80 \
  --source-ranges="10.8.0.0/14" \
  --target-tags="gke-cluster,private-cluster" \
  --description="Allow dpv2 pod CIDR to reach dpv1 ILB backend nodes on port 80"

echo ""
echo "[SUCCESS] Cross-cluster firewall rules created."
echo ""
echo "Verify:"
echo "  gcloud compute firewall-rules list --filter='name~dpv' --project=$PROJECT_ID"
