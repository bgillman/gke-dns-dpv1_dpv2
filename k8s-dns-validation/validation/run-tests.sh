#!/bin/bash
# ==============================================================================
# Phase 5 — DNS Validation Test Runner
#
# Run this script AFTER:
#   - whereami is deployed and pods are Running in both clusters
#   - ILB services show an assigned IP (not <pending>)
#   - Cloud DNS private zone and A records are created
#   - kube-dns ConfigMap is patched on gke-std-dpv1
#   - debug pod is running in the target cluster
#
# Usage:
#   CLUSTER=dpv1 bash run-tests.sh
#   CLUSTER=dpv2 bash run-tests.sh
# ==============================================================================

set -u

CLUSTER="${CLUSTER:-}"
if [ -z "$CLUSTER" ]; then
  echo "ERROR: Set CLUSTER=dpv1 or CLUSTER=dpv2 before running."
  exit 1
fi

EXEC="kubectl exec -it debug -- "

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DNS Validation — running from cluster: $CLUSTER"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Test 1: In-cluster DNS (both clusters, native) ────────────────────────────
echo ""
echo "TEST 1 — In-cluster ClusterIP DNS (local kube-dns / Cloud DNS)"
echo "  Expected: resolves to a ClusterIP in the 10.16.x.x or 10.17.x.x range"

if [ "$CLUSTER" = "dpv1" ]; then
  echo "  Query: backend.default.svc.cluster.local"
  $EXEC nslookup backend.default.svc.cluster.local
elif [ "$CLUSTER" = "dpv2" ]; then
  echo "  Query: backend.default.svc.gke-std-dpv2.local"
  $EXEC nslookup backend.default.svc.gke-std-dpv2.local
fi

# ── Test 2: HTTP response from in-cluster backend ─────────────────────────────
echo ""
echo "TEST 2 — HTTP call to in-cluster backend (confirms whereami is serving)"
echo "  Expected: JSON response with cluster metadata"

if [ "$CLUSTER" = "dpv1" ]; then
  $EXEC curl -s http://backend.default.svc.cluster.local | python3 -m json.tool 2>/dev/null || \
  $EXEC curl -s http://backend.default.svc.cluster.local
elif [ "$CLUSTER" = "dpv2" ]; then
  $EXEC curl -s http://backend.default.svc.gke-std-dpv2.local | python3 -m json.tool 2>/dev/null || \
  $EXEC curl -s http://backend.default.svc.gke-std-dpv2.local
fi

# ── Test 3: Cross-cluster DNS via Cloud DNS private zone (svc.internal) ───────
echo ""
echo "TEST 3 — Cross-cluster DNS via Cloud DNS private zone: svc.internal"

echo "  Query: backend-central.svc.internal"
echo "  Expected: resolves to dpv1 ILB IP (10.0.x.x range)"
$EXEC nslookup backend-central.svc.internal

echo ""
echo "  Query: backend-west.svc.internal"
echo "  Expected: resolves to dpv2 ILB IP (10.1.x.x range)"
$EXEC nslookup backend-west.svc.internal

# ── Test 4: HTTP call to cross-cluster backend via svc.internal ───────────────
echo ""
echo "TEST 4 — HTTP call to cross-cluster backends via svc.internal"
echo "  Expected: JSON from dpv1 backend (metadata shows gke-std-dpv1)"

$EXEC curl -s http://backend-central.svc.internal | python3 -m json.tool 2>/dev/null || \
$EXEC curl -s http://backend-central.svc.internal

echo ""
echo "  Expected: JSON from dpv2 backend (metadata shows gke-std-dpv2)"
$EXEC curl -s http://backend-west.svc.internal | python3 -m json.tool 2>/dev/null || \
$EXEC curl -s http://backend-west.svc.internal

# ── Test 5: dpv1 only — resolve dpv2 native Cloud DNS name ───────────────────
if [ "$CLUSTER" = "dpv1" ]; then
  echo ""
  echo "TEST 5 — [dpv1 only] Resolve dpv2 service via Cloud DNS VPC-scoped name"
  echo "  Requires: kube-dns stub domain for gke-std-dpv2.local"
  echo "  Query: backend.default.svc.gke-std-dpv2.local"
  echo "  Expected: resolves to dpv2 ClusterIP (10.17.x.x range)"
  echo "  NOTE: A ClusterIP is a Kubernetes-internal virtual IP — it only exists"
  echo "        inside kube-proxy on dpv2's nodes and is NOT routable across the VPC."
  echo "        A successful DNS resolution here is the full proof that the kube-dns"
  echo "        stub domain is correctly forwarding to Cloud DNS. HTTP is tested via"
  echo "        the ILB (backend-west.svc.internal) in Test 4 above."
  $EXEC nslookup backend.default.svc.gke-std-dpv2.local
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Validation complete for cluster: $CLUSTER"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
