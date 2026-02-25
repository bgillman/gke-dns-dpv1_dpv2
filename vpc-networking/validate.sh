#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# validate.sh — Post-deployment verification for vpc-networking infrastructure
#
# Usage:
#   ./validate.sh <project-id>
#   ./validate.sh                   # reads project_id from terraform.tfvars
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

PASS="${GREEN}[PASS]${RESET}"
FAIL="${RED}[FAIL]${RESET}"
INFO="${CYAN}[INFO]${RESET}"

FAILURES=0

pass() { echo -e "  ${PASS} $1"; }
fail() { echo -e "  ${FAIL} $1"; FAILURES=$((FAILURES + 1)); }
section() { echo -e "\n${BOLD}${CYAN}── $1 ${RESET}"; }

# ── Resolve project ID ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ge 1 ]]; then
  PROJECT_ID="$1"
else
  TFVARS="${SCRIPT_DIR}/terraform.tfvars"
  if [[ ! -f "${TFVARS}" ]]; then
    echo -e "${RED}ERROR:${RESET} No project ID argument and terraform.tfvars not found at ${TFVARS}"
    exit 1
  fi
  PROJECT_ID=$(grep -E '^project_id' "${TFVARS}" | sed 's/.*=\s*"\(.*\)".*/\1/')
  if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "YOUR_PROJECT_ID" ]]; then
    echo -e "${RED}ERROR:${RESET} project_id not set in terraform.tfvars. Pass it as an argument: $0 <project-id>"
    exit 1
  fi
fi

echo -e "\n${BOLD}VPC Networking Infrastructure Validation${RESET}"
echo -e "${INFO} Project: ${PROJECT_ID}\n"

# ── Helper: run gcloud and return exit code without aborting script ───────────
gcloud_check() {
  gcloud "$@" --project="${PROJECT_ID}" --quiet 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Required APIs
# ─────────────────────────────────────────────────────────────────────────────
section "Required APIs"

REQUIRED_APIS=(
  "compute.googleapis.com"
  "container.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "iam.googleapis.com"
  "logging.googleapis.com"
  "monitoring.googleapis.com"
  "dns.googleapis.com"
  "servicenetworking.googleapis.com"
  "networkmanagement.googleapis.com"
)

ENABLED_APIS=$(gcloud services list \
  --project="${PROJECT_ID}" \
  --filter="state:ENABLED" \
  --format="value(config.name)" 2>/dev/null || true)

for api in "${REQUIRED_APIS[@]}"; do
  if echo "${ENABLED_APIS}" | grep -q "^${api}$"; then
    pass "${api}"
  else
    fail "${api} — not enabled"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# 2. VPC Network
# ─────────────────────────────────────────────────────────────────────────────
section "VPC Network: vpc-global"

VPC_JSON=$(gcloud_check compute networks describe vpc-global --format=json 2>/dev/null || echo "")

if [[ -z "${VPC_JSON}" ]]; then
  fail "vpc-global — not found"
else
  pass "vpc-global exists"

  AUTO_SUBNETS=$(echo "${VPC_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('autoCreateSubnetworks', True))")
  ROUTING_MODE=$(echo "${VPC_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('routingConfig', {}).get('routingMode', 'REGIONAL'))")

  [[ "${AUTO_SUBNETS}" == "False" ]] && pass "autoCreateSubnetworks = false (custom mode)" \
    || fail "autoCreateSubnetworks should be false, got ${AUTO_SUBNETS}"

  [[ "${ROUTING_MODE}" == "GLOBAL" ]] && pass "routingMode = GLOBAL" \
    || fail "routingMode should be GLOBAL, got ${ROUTING_MODE}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Subnets
# ─────────────────────────────────────────────────────────────────────────────

check_subnet() {
  local NAME="$1"
  local REGION="$2"
  local EXPECTED_CIDR="$3"
  local PODS_RANGE="$4"
  local PODS_CIDR="$5"
  local SERVICES_RANGE="$6"
  local SERVICES_CIDR="$7"

  section "Subnet: ${NAME} (${REGION})"

  SUBNET_JSON=$(gcloud_check compute networks subnets describe "${NAME}" \
    --region="${REGION}" --format=json 2>/dev/null || echo "")

  if [[ -z "${SUBNET_JSON}" ]]; then
    fail "${NAME} — not found"
    return
  fi

  pass "${NAME} exists"

  ACTUAL_CIDR=$(echo "${SUBNET_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ipCidrRange',''))")
  PGA=$(echo "${SUBNET_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('privateIpGoogleAccess', False))")
  SECONDARY=$(echo "${SUBNET_JSON}" | python3 -c "
import sys, json
ranges = json.load(sys.stdin).get('secondaryIpRanges', [])
for r in ranges:
    print(r['rangeName'] + '=' + r['ipCidrRange'])
")

  [[ "${ACTUAL_CIDR}" == "${EXPECTED_CIDR}" ]] \
    && pass "primaryCidr = ${ACTUAL_CIDR}" \
    || fail "primaryCidr: expected ${EXPECTED_CIDR}, got ${ACTUAL_CIDR}"

  [[ "${PGA}" == "True" ]] \
    && pass "privateIpGoogleAccess = true" \
    || fail "privateIpGoogleAccess should be true, got ${PGA}"

  if echo "${SECONDARY}" | grep -q "^${PODS_RANGE}=${PODS_CIDR}$"; then
    pass "secondary range '${PODS_RANGE}' = ${PODS_CIDR}"
  else
    fail "secondary range '${PODS_RANGE}' (${PODS_CIDR}) not found — got: $(echo "${SECONDARY}" | tr '\n' ' ')"
  fi

  if echo "${SECONDARY}" | grep -q "^${SERVICES_RANGE}=${SERVICES_CIDR}$"; then
    pass "secondary range '${SERVICES_RANGE}' = ${SERVICES_CIDR}"
  else
    fail "secondary range '${SERVICES_RANGE}' (${SERVICES_CIDR}) not found — got: $(echo "${SECONDARY}" | tr '\n' ' ')"
  fi
}

check_subnet "central-vpc-subnet-01" "us-central1" \
  "10.0.0.0/20" "central-pods" "10.4.0.0/14" "central-services" "10.16.0.0/20"

check_subnet "west-vpc-subnet-01" "us-west1" \
  "10.1.0.0/20" "west-pods" "10.8.0.0/14" "west-services" "10.17.0.0/20"

check_subnet "east-vpc-subnet-01" "us-east1" \
  "10.2.0.0/20" "east-pods" "10.12.0.0/14" "east-services" "10.18.0.0/20"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Cloud Routers
# ─────────────────────────────────────────────────────────────────────────────

check_router() {
  local NAME="$1"
  local REGION="$2"
  section "Cloud Router: ${NAME} (${REGION})"

  if gcloud_check compute routers describe "${NAME}" --region="${REGION}" > /dev/null 2>&1; then
    pass "${NAME} exists in ${REGION}"
  else
    fail "${NAME} not found in ${REGION}"
  fi
}

check_router "router-central" "us-central1"
check_router "router-west"    "us-west1"
check_router "router-east"    "us-east1"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Cloud NAT
# ─────────────────────────────────────────────────────────────────────────────

check_nat() {
  local NAT_NAME="$1"
  local ROUTER_NAME="$2"
  local REGION="$3"
  section "Cloud NAT: ${NAT_NAME} (${REGION})"

  if gcloud_check compute routers nats describe "${NAT_NAME}" \
      --router="${ROUTER_NAME}" --region="${REGION}" > /dev/null 2>&1; then
    pass "${NAT_NAME} exists on ${ROUTER_NAME}"
  else
    fail "${NAT_NAME} not found on router ${ROUTER_NAME} in ${REGION}"
  fi
}

check_nat "nat-central" "router-central" "us-central1"
check_nat "nat-west"    "router-west"    "us-west1"
check_nat "nat-east"    "router-east"    "us-east1"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}────────────────────────────────────────${RESET}"
if [[ ${FAILURES} -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All checks passed.${RESET}"
else
  echo -e "${RED}${BOLD}${FAILURES} check(s) failed.${RESET}"
  exit 1
fi
echo ""
