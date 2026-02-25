# GKE Multi-Cluster DNS Validation — Dataplane V1 vs V2

This project provisions and validates a complete multi-cluster GKE environment on Google Cloud,
with a focus on comparing DNS behavior and cross-cluster service discovery between two GKE
cluster configurations: **Dataplane V1 (kube-dns)** and **Dataplane V2 (Cloud DNS)**.

Both clusters share a single global VPC, use Internal Passthrough Network Load Balancers for
cross-cluster traffic, and are validated with a full test suite covering in-cluster DNS,
in-cluster HTTP, cross-cluster DNS, and cross-cluster HTTP — including cross-region paths.

All tests passed. Full results are in [`k8s-dns-validation/validation/`](k8s-dns-validation/validation/).

---

## Repository Structure

```
gke-dns-dpv1_2/
├── vpc-networking/                        # Terraform — shared VPC, subnets, NAT
│   ├── main.tf                            # VPC, subnets, Cloud Routers, Cloud NAT
│   ├── apis.tf                            # Enables required Google Cloud APIs
│   ├── variables.tf                       # All input variables with defaults
│   ├── outputs.tf                         # Self-links, IDs, secondary range names
│   ├── validation.tf                      # Terraform check blocks (post-apply assertions)
│   ├── default-vpc-cleanup.tf             # Removes the GCP-generated default VPC
│   ├── provider.tf                        # Google provider + Terraform version constraints
│   ├── terraform.tfvars.example           # Safe committed template (no real values)
│   └── validate.sh                        # Standalone gcloud-based verification script
│
├── gke-std-private-cluster/               # GKE cluster creation scripts
│   ├── create-gke-dpv1-cluster.sh         # Creates gke-std-dpv1 (Dataplane V1, kube-dns)
│   ├── create-gke-dpv2-cluster.sh         # Creates gke-std-dpv2 (Dataplane V2, Cloud DNS)
│   ├── create-gke-cluster.sh              # Generic zonal cluster script
│   ├── create-gke-regional-cluster.sh     # Generic regional cluster script
│   ├── config.sh.example                  # Configuration template (copy to config.sh)
│   └── README.md                          # Script-specific documentation
│
└── k8s-dns-validation/                    # Kubernetes manifests and validation results
    ├── dpv1/                              # Workloads for gke-std-dpv1
    │   ├── backend-deployment.yaml        # whereami Deployment (3 replicas)
    │   ├── backend-svc-clusterip.yaml     # ClusterIP Service
    │   └── backend-svc-ilb.yaml           # Internal Passthrough NLB (global access)
    ├── dpv2/                              # Workloads for gke-std-dpv2
    │   ├── backend-deployment.yaml        # whereami Deployment (3 replicas)
    │   ├── backend-svc-clusterip.yaml     # ClusterIP Service
    │   └── backend-svc-ilb.yaml           # Internal Passthrough NLB (global access)
    ├── kube-dns/
    │   └── kube-dns-stub-domains.yaml     # ConfigMap patch for dpv1 cross-cluster DNS
    ├── cloud-dns/
    │   ├── 01-create-zone.sh              # Creates svc.internal Cloud DNS private zone
    │   ├── 02-add-records.sh              # Adds A records for both ILB IPs
    │   └── 03-cross-cluster-firewall.sh   # Creates cross-cluster firewall rules
    └── validation/
        ├── debug-pod.yaml                 # nicolaka/netshoot debug pod (deploy to both clusters)
        ├── dpv1-validation.md             # Full test results for gke-std-dpv1
        ├── dpv2-validation.md             # Full test results for gke-std-dpv2
        ├── internal-network-lb.md         # Deep dive: ILB architecture and annotations
        ├── validation-commands.md         # Reference validation commands
        └── run-tests.sh                   # Automated test runner
```

---

## Architecture Overview

```
Google Cloud Project: gillman-gke-dns
└── vpc-global  (custom-mode VPC, GLOBAL routing mode)
    │
    ├── central-vpc-subnet-01  (us-central1)
    │   ├── Nodes: 10.0.0.0/20
    │   ├── Pods:  10.4.0.0/14  (secondary range: central-pods)
    │   └── Svcs:  10.16.0.0/20 (secondary range: central-services)
    │   └── [GKE Cluster: gke-std-dpv1]
    │       ├── DNS: kube-dns (cluster.local)
    │       ├── CNI: Dataplane V1 (LEGACY_DATAPATH / standard kube-proxy)
    │       └── ILB: backend-central.svc.internal → 10.0.0.11
    │
    ├── west-vpc-subnet-01  (us-west1)
    │   ├── Nodes: 10.1.0.0/20
    │   ├── Pods:  10.8.0.0/14  (secondary range: west-pods)
    │   └── Svcs:  10.17.0.0/20 (secondary range: west-services)
    │   └── [GKE Cluster: gke-std-dpv2]
    │       ├── DNS: Cloud DNS (gke-std-dpv2.local, VPC scope)
    │       ├── CNI: Dataplane V2 (ADVANCED_DATAPATH / eBPF)
    │       └── ILB: backend-west.svc.internal → 10.1.0.6
    │
    ├── east-vpc-subnet-01  (us-east1)  [provisioned, no cluster deployed]
    │   ├── Nodes: 10.2.0.0/20
    │   ├── Pods:  10.12.0.0/14
    │   └── Svcs:  10.18.0.0/20
    │
    ├── Cloud DNS private zone: svc.internal (visibility=private, network=vpc-global)
    │   ├── backend-central.svc.internal → 10.0.0.11  (dpv1 ILB)
    │   └── backend-west.svc.internal    → 10.1.0.6   (dpv2 ILB)
    │
    ├── Cloud Router + Cloud NAT — one pair per region (central, west, east)
    │
    └── Firewall rules (cross-cluster ingress on tcp:80)
        ├── allow-dpv1-pods-to-dpv2-ilb  (source: 10.4.0.0/14 → tags: gke-cluster)
        └── allow-dpv2-pods-to-dpv1-ilb  (source: 10.8.0.0/14 → tags: gke-cluster)
```

---

## IP Address Plan

| Resource | CIDR / Address | Description |
|---|---|---|
| `central-vpc-subnet-01` | `10.0.0.0/20` | GKE nodes — us-central1 |
| `west-vpc-subnet-01` | `10.1.0.0/20` | GKE nodes — us-west1 |
| `east-vpc-subnet-01` | `10.2.0.0/20` | GKE nodes — us-east1 |
| `central-pods` | `10.4.0.0/14` | GKE pods — us-central1 (10.4.0.0–10.7.255.255) |
| `west-pods` | `10.8.0.0/14` | GKE pods — us-west1 (10.8.0.0–10.11.255.255) |
| `east-pods` | `10.12.0.0/14` | GKE pods — us-east1 (10.12.0.0–10.15.255.255) |
| `central-services` | `10.16.0.0/20` | GKE services — us-central1 |
| `west-services` | `10.17.0.0/20` | GKE services — us-west1 |
| `east-services` | `10.18.0.0/20` | GKE services — us-east1 |
| dpv1 kube-dns ClusterIP | `10.16.0.10` | In-cluster resolver for gke-std-dpv1 |
| dpv1 ILB (`backend-ilb`) | `10.0.0.11` | Internal LB from central-vpc-subnet-01 |
| dpv2 Cloud DNS stub | `169.254.20.10` | Node-local stub resolver — link-local, per-node |
| dpv2 ILB (`backend-ilb`) | `10.1.0.6` | Internal LB from west-vpc-subnet-01 |
| GCP Cloud DNS resolver | `169.254.169.254` | VPC metadata / Cloud DNS resolver |

---

## Cluster Configuration Comparison

| Property | `gke-std-dpv1` | `gke-std-dpv2` |
|---|---|---|
| **Region / Zone** | `us-central1` / `us-central1-a` | `us-west1` / `us-west1-a` |
| **Dataplane** | V1 — `LEGACY_DATAPATH` (kube-proxy) | V2 — `ADVANCED_DATAPATH` (eBPF) |
| **DNS provider** | kube-dns | Cloud DNS |
| **Cluster DNS domain** | `cluster.local` | `gke-std-dpv2.local` |
| **DNS resolver address** | `10.16.0.10` (kube-dns ClusterIP) | `169.254.20.10` (node-local stub) |
| **DNS scope** | Cluster-only | VPC-scoped (`--cluster-dns-scope=vpc`) |
| **Control plane access** | DNS endpoint only (`--enable-dns-access`, `--no-enable-ip-access`) | DNS endpoint only |
| **Control plane public IP** | None | None |
| **Node subnet** | `central-vpc-subnet-01` (`10.0.0.0/20`) | `west-vpc-subnet-01` (`10.1.0.0/20`) |
| **Pod CIDR** | `10.4.0.0/14` (`central-pods`) | `10.8.0.0/14` (`west-pods`) |
| **Service CIDR** | `10.16.0.0/20` (`central-services`) | `10.17.0.0/20` (`west-services`) |
| **Node count** | 3 × `e2-medium` | 3 × `e2-medium` |
| **Workload Identity** | `gillman-gke-dns.svc.id.goog` | `gillman-gke-dns.svc.id.goog` |
| **Shielded nodes** | Enabled | Enabled |
| **DPv2 eBPF metrics** | N/A | Enabled |
| **DPv2 flow observability** | N/A | Enabled |
| **Managed Prometheus** | Enabled | Enabled |
| **Release channel** | rapid | rapid |
| **Node OS** | COS_CONTAINERD | COS_CONTAINERD |
| **Node tags** | `gke-cluster`, `private-cluster` | `gke-cluster`, `private-cluster` |

---

## DNS Architecture Deep Dive

### gke-std-dpv1 — kube-dns

kube-dns is a Kubernetes Deployment (2–3 pods) managed by GKE. It runs in the `kube-system`
namespace and is assigned a stable ClusterIP (`10.16.0.10`). Every pod's `/etc/resolv.conf`
points to this ClusterIP as `nameserver`.

- kube-dns is the **authoritative resolver** for `cluster.local` — it returns the `aa`
  (Authoritative Answer) DNS flag for all in-cluster service names.
- kube-dns does **not** support open recursion (`ra` flag is absent in responses). External
  domains are handled via **stub domain forwarding rules** in a ConfigMap.
- The `kube-dns-stub-domains.yaml` ConfigMap patch in this project adds two forwarding rules,
  both pointing to `169.254.169.254` (GCP's Cloud DNS VPC resolver):
  - `gke-std-dpv2.local` — so dpv1 pods can resolve dpv2's native Cloud DNS service names
  - `svc.internal` — so dpv1 pods can resolve the cross-cluster `svc.internal` private zone

```yaml
# k8s-dns-validation/kube-dns/kube-dns-stub-domains.yaml
stubDomains: |
  {
    "gke-std-dpv2.local": ["169.254.169.254"],
    "svc.internal":       ["169.254.169.254"]
  }
```

This ConfigMap patch is **required on dpv1** and completely absent on dpv2.

### gke-std-dpv2 — Cloud DNS (node-local stub)

When `--cluster-dns=clouddns --cluster-dns-scope=vpc` is specified at cluster creation, GKE
replaces kube-dns with a **node-local Cloud DNS stub resolver** at `169.254.20.10`. This is
a per-node OS-level process (managed by systemd as part of GKE node bootstrap), not a
Kubernetes Deployment. It does not appear in `kubectl get pods` or `kubectl get svc`.

Key characteristics:
- Bound to the link-local address `169.254.20.10:53` — never routed, strictly per-host
- Forwards all queries to `169.254.169.254` (Cloud DNS VPC resolver)
- VPC scope (`--cluster-dns-scope=vpc`) means **all private Cloud DNS zones attached to
  `vpc-global` are automatically resolvable** — including `svc.internal` — with no ConfigMap
  configuration required
- Cloud DNS returns **Non-authoritative** answers even for the cluster's own domain
  (`gke-std-dpv2.local`), which is expected — Cloud DNS is a managed service, not a
  traditional authoritative nameserver

### DNS resolver comparison

| Property | kube-dns (dpv1) | Cloud DNS node-local stub (dpv2) |
|---|---|---|
| What it is | Kubernetes Deployment (2–3 pods) | OS-level daemon per node |
| Visible in `kubectl` | Yes — `kubectl get svc kube-dns -n kube-system` | No |
| Address | ClusterIP `10.16.0.10` (kube-proxy virtual IP) | Link-local `169.254.20.10` |
| Authoritative for cluster domain | Yes (`aa` flag present) | No (`aa` flag absent) |
| External zone forwarding | Manual — stub domain ConfigMap per suffix | Automatic — VPC scope resolves all private zones |
| Blast radius of failure | Cluster-wide (all pods lose DNS) | Single node only |
| `svc.internal` resolution | Requires explicit stub domain entry | Native — no config needed |

---

## Deployment Guide

### Prerequisites

- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- `terraform` >= 1.5.0
- A Google Cloud project with billing enabled
- The authenticated identity must have `roles/editor` or equivalent for initial setup

### Phase 1 — VPC Networking (Terraform)

```bash
cd vpc-networking/

# Set required variable (never committed)
export TF_VAR_project_id="your-project-id"

# Deploy
terraform init
terraform plan
terraform apply

# Verify
./validate.sh
```

This single `terraform apply` will:
1. Enable 9 required Google Cloud APIs
2. Delete the default VPC and its permissive firewall rules
3. Create `vpc-global` (custom mode, GLOBAL routing)
4. Create 3 subnets with secondary pod/service ranges
5. Create Cloud Routers and Cloud NAT in each region

### Phase 2 — Create GKE Clusters

Both clusters are created from the `gke-std-private-cluster/` directory. Each requires its own
`config.sh` (derived from `config.sh.example`). The `config.sh` file is gitignored.

**Create gke-std-dpv1 (Dataplane V1, kube-dns, us-central1):**

```bash
cd gke-std-private-cluster/
cp config.sh.example config.sh
# Edit config.sh: set PROJECT_ID, CLUSTER_NAME=gke-std-dpv1, REGION=us-central1,
#   ZONE=us-central1-a, VPC_NETWORK_NAME=vpc-global, VPC_SUBNET_NAME=central-vpc-subnet-01,
#   POD_RANGE_NAME=central-pods, SERVICES_RANGE_NAME=central-services,
#   POD_CIDR=10.4.0.0/14, SERVICE_CIDR=10.16.0.0/20

chmod +x create-gke-dpv1-cluster.sh
./create-gke-dpv1-cluster.sh
```

**Create gke-std-dpv2 (Dataplane V2, Cloud DNS, us-west1):**

```bash
# Update config.sh: set CLUSTER_NAME=gke-std-dpv2, REGION=us-west1, ZONE=us-west1-a,
#   VPC_SUBNET_NAME=west-vpc-subnet-01, POD_RANGE_NAME=west-pods,
#   SERVICES_RANGE_NAME=west-services, POD_CIDR=10.8.0.0/14, SERVICE_CIDR=10.17.0.0/20,
#   CLUSTER_DNS_DOMAIN=gke-std-dpv2.local

chmod +x create-gke-dpv2-cluster.sh
./create-gke-dpv2-cluster.sh
```

Both scripts will:
- Enable required APIs
- Display configuration and prompt for confirmation
- Create the cluster (~10–15 min)
- Configure `kubectl` credentials (DNS endpoint)
- Verify cluster configuration (dataplane, DNS, Workload Identity, private nodes)

**Cluster access:** Both clusters use DNS-based endpoint only (`--enable-dns-access`,
`--no-enable-ip-access`). No public IP is assigned to either control plane. Access requires
running from within Google Cloud (GCE VM, Cloud Shell, GKE pod) or via VPN/Interconnect.

```bash
# Retrieve credentials (DNS endpoint)
gcloud container clusters get-credentials CLUSTER_NAME \
  --region=REGION \
  --project=PROJECT_ID \
  --dns-endpoint
```

### Phase 3 — Deploy Kubernetes Workloads

Deploy the `whereami` backend service to both clusters. The `whereami` image returns a JSON
response identifying the cluster, pod, node, region, and zone — which makes cross-cluster
traffic verification unambiguous.

```bash
# Terminal 1 — gke-std-dpv1 context
kubectl apply -f k8s-dns-validation/dpv1/backend-deployment.yaml
kubectl apply -f k8s-dns-validation/dpv1/backend-svc-clusterip.yaml
kubectl apply -f k8s-dns-validation/dpv1/backend-svc-ilb.yaml
kubectl apply -f k8s-dns-validation/validation/debug-pod.yaml

# Terminal 2 — gke-std-dpv2 context
kubectl apply -f k8s-dns-validation/dpv2/backend-deployment.yaml
kubectl apply -f k8s-dns-validation/dpv2/backend-svc-clusterip.yaml
kubectl apply -f k8s-dns-validation/dpv2/backend-svc-ilb.yaml
kubectl apply -f k8s-dns-validation/validation/debug-pod.yaml

# Wait for ILBs to receive an IP (may take 60–90 seconds)
# Terminal 1:
kubectl get svc backend-ilb -w

# Terminal 2:
kubectl get svc backend-ilb -w
```

Record both ILB IPs before proceeding:

```bash
# Terminal 1 (dpv1):
kubectl get svc backend-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
# Expected: 10.0.0.11

# Terminal 2 (dpv2):
kubectl get svc backend-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
# Expected: 10.1.0.6
```

### Phase 4 — Cloud DNS Private Zone

Create the `svc.internal` Cloud DNS private zone and add A records pointing to both ILBs.
This zone is scoped to `vpc-global`, making it resolvable from all resources in the VPC.

```bash
cd k8s-dns-validation/cloud-dns/

# Create the zone (run once)
./01-create-zone.sh

# Add A records (fill in the ILB IPs recorded in Phase 3 first)
# Edit 02-add-records.sh: set DPV1_ILB_IP and DPV2_ILB_IP
./02-add-records.sh

# Verify
gcloud dns record-sets list --zone=svc-internal --project=gillman-gke-dns
```

### Phase 5 — kube-dns Stub Domains (dpv1 only)

dpv2 automatically resolves all VPC-scoped Cloud DNS zones — no configuration needed.
dpv1 requires explicit stub domain entries in the kube-dns ConfigMap.

```bash
# Apply in Terminal 1 (gke-std-dpv1 context)
kubectl apply -f k8s-dns-validation/kube-dns/kube-dns-stub-domains.yaml

# Verify the ConfigMap was updated
kubectl get configmap kube-dns -n kube-system -o yaml
```

### Phase 6 — Cross-cluster Firewall Rules

GKE automatically creates firewall rules for Internal LB traffic, but those rules only allow
sources from within the same cluster's node and pod CIDRs. Two additional rules are required
to allow each cluster's pod CIDR to reach the other cluster's nodes.

```bash
cd k8s-dns-validation/cloud-dns/
./03-cross-cluster-firewall.sh

# Verify
gcloud compute firewall-rules list --filter='name~dpv' --project=gillman-gke-dns
```

---

## Internal Load Balancer Architecture

Both clusters expose a `backend-ilb` Kubernetes Service of `type: LoadBalancer`. The two
critical annotations on each manifest are:

**`cloud.google.com/load-balancer-type: "Internal"`**

Instructs the GKE cloud-controller-manager to provision a GCP Internal Passthrough Network
Load Balancer (instead of external). The IP is allocated from the cluster's node subnet.

**`networking.gke.io/internal-load-balancer-allow-global-access: "true"`**

By default, GCP Internal Passthrough NLBs are **regional** — they only accept traffic sourced
from the same region as the forwarding rule. Without this annotation, cross-region HTTP calls
(dpv1 pods in `us-central1` reaching the dpv2 ILB in `us-west1`) are silently dropped at the
GCP load balancer layer, before firewall rules are even evaluated.

With global access enabled, the cross-region traffic flow works bidirectionally:

```
dpv1 pod (us-central1) → VPC GLOBAL routing → dpv2 ILB (us-west1, 10.1.0.6) → dpv2 pod
dpv2 pod (us-west1)    → VPC GLOBAL routing → dpv1 ILB (us-central1, 10.0.0.11) → dpv1 pod
```

The ILB is **passthrough** — it does not terminate TCP. Backend pods see the original source IP
of the calling pod. Traffic path within the cluster:

```
ILB:80 → NodePort:30xxx → Pod:8080
```

---

## Validation Results

Both cluster test suites passed completely. Full output and analysis is in the validation files.

### gke-std-dpv1 (kube-dns) — All Tests Passed

| Test | Description | Result |
|---|---|---|
| 1 | In-cluster DNS — `backend.default.svc.cluster.local` via kube-dns | ✅ Pass |
| 2 | In-cluster HTTP — `whereami` confirms cluster identity | ✅ Pass |
| 3a | Cross-cluster DNS — `backend-central.svc.internal` → `10.0.0.11` | ✅ Pass |
| 3b | Cross-cluster DNS — `backend-west.svc.internal` → `10.1.0.6` | ✅ Pass |
| 4a | Cross-cluster HTTP — dpv1 ILB loopback (same cluster) | ✅ Pass |
| 4b | Cross-cluster HTTP — dpv2 ILB cross-region (`us-central1` → `us-west1`) | ✅ Pass |
| 5 | kube-dns stub domain → dpv2 Cloud DNS (`backend.default.svc.gke-std-dpv2.local`) | ✅ Pass |

**Test 4b** (headline result from dpv1): confirms the full cross-region path —
dpv1 pod → kube-dns stub domain → Cloud DNS `svc.internal` A record → dpv2 ILB
(global access) → dpv2 backend pod in `us-west1`.

```json
{
    "cluster_name": "gke-std-dpv2",
    "host_header": "backend-west.svc.internal",
    "metadata": "cluster=gke-std-dpv2 | region=us-west1 | dns=cloud-dns | subnet=west-vpc-subnet-01",
    "pod_ip": "10.8.2.16",
    "zone": "us-west1-a"
}
```

### gke-std-dpv2 (Cloud DNS) — All Tests Passed

| Test | Description | Result |
|---|---|---|
| 1 | In-cluster DNS — `backend.default.svc.gke-std-dpv2.local` via Cloud DNS stub | ✅ Pass |
| 2 | In-cluster HTTP — `whereami` confirms cluster identity | ✅ Pass |
| 3a | Cross-cluster DNS — `backend-central.svc.internal` → `10.0.0.11` | ✅ Pass |
| 3b | Cross-cluster DNS — `backend-west.svc.internal` → `10.1.0.6` | ✅ Pass |
| 4a | Cross-cluster HTTP — dpv1 ILB cross-region (`us-west1` → `us-central1`) | ✅ Pass |
| 4b | Cross-cluster HTTP — dpv2 ILB loopback (same cluster) | ✅ Pass |

**Zero ConfigMap configuration required on dpv2.** All cross-cluster DNS resolution —
including `svc.internal` and `gke-std-dpv2.local` from dpv1 — worked natively via
Cloud DNS VPC scope.

---

## Issues Encountered and Resolved

### 1. Pod CIDR conflict on cluster creation

**Symptom:** Cluster creation failed with a CIDR conflict error.

**Root cause:** The cluster creation script passed `--cluster-ipv4-cidr` with a CIDR that was
already allocated as a named secondary range by Terraform. GKE tried to create a new secondary
range with the same CIDR, conflicting with the existing one.

**Fix:** Replaced `--cluster-ipv4-cidr` with `--cluster-secondary-range-name` (referencing the
Terraform-created range by name) and added `--services-secondary-range-name` for the same
reason. GKE now attaches to the pre-existing secondary ranges instead of trying to create new ones.

### 2. Control plane public IP

**Symptom:** The cluster was created with a public IP on the control plane.

**Root cause:** The original script included `--enable-ip-access`, which causes GKE to assign
a public IP-based endpoint to the control plane.

**Fix:** Replaced with `--no-enable-ip-access` and `--enable-dns-access`. The DNS-based
endpoint is the sole access method. The control plane has no public IP, no master authorized
network flags are needed, and `kubectl` traffic routes through Google's private network.

### 3. Internal LB cross-region timeout

**Symptom:** HTTP calls from dpv1 pods to `backend-west.svc.internal` (`10.1.0.6`) timed out
despite correct DNS resolution — `nslookup` returned the right IP but `curl` hung.

**Root cause:** GCP Internal Passthrough NLBs are **regional by default**. Traffic sourced
from `us-central1` (dpv1 pods) reaching a `us-west1` forwarding rule at `10.1.0.6` was
silently dropped at the load balancer layer. This happens before firewall rules are evaluated,
so no firewall log entries appeared.

**Fix:** Added `networking.gke.io/internal-load-balancer-allow-global-access: "true"` to
both ILB Service manifests. This upgrades the forwarding rule to global access mode, accepting
traffic from any region within the VPC.

---

## Key gcloud Commands

### Cluster management

```bash
# Get credentials (DNS endpoint — required for private clusters)
gcloud container clusters get-credentials CLUSTER_NAME \
  --region=REGION --project=PROJECT_ID --dns-endpoint

# Describe cluster (verify dataplane, DNS config, private node config)
gcloud container clusters describe gke-std-dpv1 \
  --region=us-central1 --project=gillman-gke-dns \
  --format='table(name,networkConfig.datapathProvider,networkConfig.dnsConfig,status)'

# Verify control plane endpoint configuration
gcloud container clusters describe gke-std-dpv2 \
  --region=us-west1 --project=gillman-gke-dns \
  --format='table(
    controlPlaneEndpointsConfig.ipEndpointsConfig.enabled,
    controlPlaneEndpointsConfig.dnsEndpointConfig.enabled,
    controlPlaneEndpointsConfig.dnsEndpointConfig.endpoint
  )'
```

### DNS validation

```bash
# Verify Cloud DNS private zone scope
gcloud dns managed-zones describe svc-internal \
  --project=gillman-gke-dns \
  --format='table(name,dnsName,visibility,privateVisibilityConfig.networks[].networkUrl)'

# List all A records in the zone
gcloud dns record-sets list --zone=svc-internal --project=gillman-gke-dns

# In-cluster DNS resolution (from debug pod)
kubectl exec -it debug -- nslookup backend.default.svc.cluster.local     # dpv1
kubectl exec -it debug -- nslookup backend.default.svc.gke-std-dpv2.local # dpv2
kubectl exec -it debug -- nslookup backend-central.svc.internal           # both clusters
kubectl exec -it debug -- nslookup backend-west.svc.internal              # both clusters
```

### ILB and firewall validation

```bash
# Confirm ILB IP and global access annotation
kubectl get svc backend-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
kubectl get svc backend-ilb -o jsonpath='{.metadata.annotations}{"\n"}'

# List internal forwarding rules created by GKE
gcloud compute forwarding-rules list \
  --project=gillman-gke-dns \
  --filter='loadBalancingScheme=INTERNAL' \
  --format='table(name,IPAddress,region,loadBalancingScheme)'

# Verify cross-cluster firewall rules
gcloud compute firewall-rules list \
  --filter='name~dpv' --project=gillman-gke-dns \
  --format='table(name,direction,sourceRanges,targetTags,allowed)'
```

### Cross-cluster HTTP validation

```bash
# From debug pod in either cluster:
kubectl exec -it debug -- curl -s http://backend-central.svc.internal
# Expected response: cluster_name: gke-std-dpv1, zone: us-central1-a

kubectl exec -it debug -- curl -s http://backend-west.svc.internal
# Expected response: cluster_name: gke-std-dpv2, zone: us-west1-a
```

---

## Security Features

Both clusters are configured with a hardened security posture:

| Feature | Configuration |
|---|---|
| **Private nodes** | Worker node VMs have no external IPs (`--enable-private-nodes`) |
| **Private control plane** | No public IP, no IP-based endpoint (`--no-enable-ip-access`) |
| **DNS endpoint** | Sole access method — traffic stays on Google's private network |
| **Workload Identity** | `PROJECT_ID.svc.id.goog` — secure pod-to-GCP-service auth |
| **Shielded nodes** | Integrity monitoring enabled; secure boot configurable |
| **No basic auth** | `--no-enable-basic-auth` |
| **Legacy endpoints disabled** | `--metadata=disable-legacy-endpoints=true` |
| **VPC Flow Logs** | 50% sample, 5-second intervals, full metadata on all subnets |
| **Cloud NAT logging** | ERRORS_ONLY — surfaces port exhaustion and translation failures |
| **Default VPC removed** | Deleted by Terraform — no implicit networks exist in the project |

---

## Monitoring and Observability

Both clusters enable the full monitoring stack:

- **Managed Prometheus** — Prometheus-compatible metrics scraping
- **System metrics** — node, cluster
- **Storage metrics** — PV, PVC
- **Pod metrics** — CPU, memory, network
- **Deployment / StatefulSet / DaemonSet / HPA** metrics
- **Kubelet and cAdvisor** metrics
- **DCGM** — GPU metrics (available if GPU nodes are added)
- **DPv2 eBPF metrics** (dpv2 only) — advanced network flow metrics
- **DPv2 flow observability** (dpv2 only) — per-connection flow visibility

```bash
kubectl top nodes
kubectl top pods --all-namespaces
```

---

## References

- [GKE Dataplane V2](https://cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2)
- [Cloud DNS for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/cloud-dns)
- [GKE Private Clusters](https://cloud.google.com/kubernetes-engine/docs/concepts/private-cluster-concept)
- [Internal Passthrough Network Load Balancers](https://cloud.google.com/load-balancing/docs/internal)
- [GKE DNS-based endpoint](https://cloud.google.com/kubernetes-engine/docs/concepts/control-plane-endpoints)
- [VPC routing modes](https://cloud.google.com/vpc/docs/vpc#routing_for_hybrid_networks)
- [Cloud DNS private zones](https://cloud.google.com/dns/docs/zones/zones-overview#private_zones)
