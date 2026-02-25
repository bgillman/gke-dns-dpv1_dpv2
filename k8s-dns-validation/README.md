# k8s-dns-validation

This directory contains all Kubernetes manifests, Cloud DNS setup scripts, and validation
tooling for the multi-cluster DNS comparison between `gke-std-dpv1` (kube-dns) and
`gke-std-dpv2` (Cloud DNS).

Work through the phases in order. Each phase depends on the previous one completing
successfully.

---

## Prerequisites

Before starting, confirm the following are in place:

- [ ] VPC networking deployed (`vpc-networking/` Terraform applied and validated)
- [ ] `gke-std-dpv1` cluster running in `us-central1`
- [ ] `gke-std-dpv2` cluster running in `us-west1`
- [ ] Two terminal sessions open — one with `kubectl` pointed at each cluster
- [ ] `gcloud` authenticated with access to the project

**Verify your kubectl contexts before running any commands:**

```bash
# List available contexts
kubectl config get-contexts

# Switch between clusters as needed
kubectl config use-context <dpv1-context-name>
kubectl config use-context <dpv2-context-name>
```

If you created the clusters using the scripts in `gke-std-private-cluster/`, credentials
were already fetched via `--dns-endpoint`. Re-fetch if needed:

```bash
gcloud container clusters get-credentials gke-std-dpv1 \
  --region=us-central1 --project=PROJECT_ID --dns-endpoint

gcloud container clusters get-credentials gke-std-dpv2 \
  --region=us-west1 --project=PROJECT_ID --dns-endpoint
```

---

## Directory Structure

```
k8s-dns-validation/
├── dpv1/                              # Workload manifests for gke-std-dpv1
│   ├── backend-deployment.yaml        # whereami Deployment — 3 replicas
│   ├── backend-svc-clusterip.yaml     # ClusterIP Service — in-cluster DNS target
│   └── backend-svc-ilb.yaml           # Internal Passthrough NLB — cross-cluster target
├── dpv2/                              # Workload manifests for gke-std-dpv2
│   ├── backend-deployment.yaml        # whereami Deployment — 3 replicas
│   ├── backend-svc-clusterip.yaml     # ClusterIP Service — in-cluster DNS target
│   └── backend-svc-ilb.yaml           # Internal Passthrough NLB — cross-cluster target
├── kube-dns/
│   └── kube-dns-stub-domains.yaml     # ConfigMap patch — enables cross-cluster DNS on dpv1
├── cloud-dns/
│   ├── 01-create-zone.sh              # Creates the svc.internal Cloud DNS private zone
│   ├── 02-add-records.sh              # Adds A records for both cluster ILBs
│   └── 03-cross-cluster-firewall.sh   # Creates cross-cluster firewall rules
└── validation/
    ├── debug-pod.yaml                 # nicolaka/netshoot debug pod — deploy to both clusters
    ├── run-tests.sh                   # Automated test runner
    ├── dpv1-validation.md             # Full recorded test results for gke-std-dpv1
    ├── dpv2-validation.md             # Full recorded test results for gke-std-dpv2
    ├── internal-network-lb.md         # Deep dive: ILB architecture and annotations
    └── validation-commands.md         # Manual validation command reference
```

---

## Phase 1 — Deploy Workloads to Both Clusters

### What you are deploying

The workload is **whereami** — a lightweight Google-provided HTTP server that returns a JSON
response describing itself: cluster name, pod name, pod IP, node name, zone, project, and a
`metadata` field that is set via environment variable at deploy time. This makes it easy to
confirm not just that a response was received, but exactly which cluster and pod it came from.

All manifests in `dpv1/` and `dpv2/` are nearly identical — the only differences are the
`cluster` label and the `METADATA` environment variable, which are set to the respective
cluster's name and attributes so every response is self-identifying.

### 1a — Deploy to gke-std-dpv1

Run these commands in **Terminal 1** (kubectl context: `gke-std-dpv1`):

```bash
# Deployment — 3 replicas of whereami
kubectl apply -f dpv1/backend-deployment.yaml

# ClusterIP Service — in-cluster DNS target for Test 1 and Test 2
kubectl apply -f dpv1/backend-svc-clusterip.yaml

# Internal LB — cross-cluster DNS and HTTP target for Tests 3 and 4
kubectl apply -f dpv1/backend-svc-ilb.yaml

# Debug pod — the test harness for all validation commands
kubectl apply -f validation/debug-pod.yaml
```

Wait for pods to be Running and the ILB to receive an IP:

```bash
# Watch pods — wait for all 3 to show Running
kubectl get pods -l app=backend -w

# Watch the ILB — wait until EXTERNAL-IP shows an IP, not <pending>
# (despite the column name, this is an internal IP from the node subnet)
kubectl get svc backend-ilb -w
```

The ILB IP will come from the `central-vpc-subnet-01` range (`10.0.0.0/20`).

**Record the dpv1 ILB IP** — you will need it in Phase 2:

```bash
kubectl get svc backend-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
```

### 1b — Deploy to gke-std-dpv2

Run these commands in **Terminal 2** (kubectl context: `gke-std-dpv2`):

```bash
kubectl apply -f dpv2/backend-deployment.yaml
kubectl apply -f dpv2/backend-svc-clusterip.yaml
kubectl apply -f dpv2/backend-svc-ilb.yaml
kubectl apply -f validation/debug-pod.yaml
```

Wait for pods and ILB:

```bash
kubectl get pods -l app=backend -w
kubectl get svc backend-ilb -w
```

The ILB IP will come from the `west-vpc-subnet-01` range (`10.1.0.0/20`).

**Record the dpv2 ILB IP** — you will need it in Phase 2:

```bash
kubectl get svc backend-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
```

### Manifest walkthrough

#### `backend-deployment.yaml`

```yaml
replicas: 3
```
Three replicas spread across nodes. This ensures DNS resolution exercises real load balancing
and validates that multiple endpoints are registered.

```yaml
image: us-docker.pkg.dev/google-samples/containers/gke/whereami:v1.2.23
```
The whereami image. It listens on port `8080` and responds to any HTTP request with a JSON
payload describing the pod. The `/healthz` endpoint returns `200 OK` and is used for both
readiness and liveness probes.

```yaml
- name: METADATA
  value: "cluster=gke-std-dpv1 | region=us-central1 | dns=kube-dns | subnet=central-vpc-subnet-01"
```
This string is embedded in every HTTP response under the `metadata` key. It is the primary
way to confirm which cluster responded to a cross-cluster HTTP call — the response itself
tells you the answer without needing to inspect headers or check logs.

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "64Mi"
  limits:
    cpu: "200m"
    memory: "128Mi"
```
Conservative resource requests suitable for lab clusters. Adjust for production use.

#### `backend-svc-clusterip.yaml`

```yaml
type: ClusterIP
port: 80
targetPort: 8080
```
A standard in-cluster service. GKE assigns a virtual IP from the cluster's services CIDR
(`10.16.0.0/20` for dpv1, `10.17.0.0/20` for dpv2). This IP is only reachable from within
the cluster — it is not routable across the VPC. This service is the DNS target for Tests 1
and 2 (in-cluster DNS and HTTP).

#### `backend-svc-ilb.yaml`

```yaml
annotations:
  cloud.google.com/load-balancer-type: "Internal"
  networking.gke.io/internal-load-balancer-allow-global-access: "true"
type: LoadBalancer
port: 80
targetPort: 8080
```

Two annotations, both critical:

- `cloud.google.com/load-balancer-type: "Internal"` — provisions a GCP Internal Passthrough
  Network Load Balancer. The IP is allocated from the node subnet (not the pod or service
  CIDR), making it routable within the VPC.

- `networking.gke.io/internal-load-balancer-allow-global-access: "true"` — by default, GCP
  Internal Passthrough NLBs are regional and only accept traffic from the same region. Without
  this annotation, cross-region HTTP calls are silently dropped at the GCP load balancer layer
  before any firewall rule is evaluated. This annotation enables global access so that pods in
  `us-central1` can reach the dpv2 ILB in `us-west1`, and vice versa.

#### `validation/debug-pod.yaml`

```yaml
image: nicolaka/netshoot:latest
command: ["sleep", "infinity"]
```

`nicolaka/netshoot` is a network troubleshooting container that includes `curl`, `dig`,
`nslookup`, `ping`, `tcpdump`, `traceroute`, and many other tools. The pod sleeps indefinitely
so you can `kubectl exec` into it repeatedly to run tests. Deploy this to **both clusters** —
the same manifest works in both because it contains no cluster-specific values.

---

## Phase 2 — Cloud DNS Private Zone

This phase creates a Cloud DNS private zone named `svc.internal` and registers the ILB IPs
from Phase 1 as A records. The zone is scoped to `vpc-global`, making it resolvable from any
resource in the VPC — including pods in both clusters.

### 2a — Create the zone

```bash
cd cloud-dns/
./01-create-zone.sh
```

This creates a private Cloud DNS zone with:
- **DNS name:** `svc.internal.`
- **Visibility:** private (not resolvable from the internet)
- **Network scope:** `vpc-global` — the zone is attached to the VPC, so any resource in
  `vpc-global` can resolve names in it

Verify the zone was created:

```bash
gcloud dns managed-zones describe svc-internal \
  --project=PROJECT_ID \
  --format='table(name,dnsName,visibility,privateVisibilityConfig.networks[].networkUrl)'
```

### 2b — Add A records

Before running the next script, open `cloud-dns/02-add-records.sh` and fill in the two ILB
IPs you recorded in Phase 1:

```bash
DPV1_ILB_IP="<dpv1 ILB IP>"   # from central-vpc-subnet-01 (10.0.0.0/20)
DPV2_ILB_IP="<dpv2 ILB IP>"   # from west-vpc-subnet-01 (10.1.0.0/20)
```

Then run:

```bash
./02-add-records.sh
```

This creates two A records in the `svc-internal` zone:

| DNS name | Points to | Cluster |
|---|---|---|
| `backend-central.svc.internal` | dpv1 ILB IP | `gke-std-dpv1` in `us-central1` |
| `backend-west.svc.internal` | dpv2 ILB IP | `gke-std-dpv2` in `us-west1` |

Verify both records:

```bash
gcloud dns record-sets list \
  --zone=svc-internal \
  --project=PROJECT_ID \
  --format='table(name,type,ttl,rrdatas)'
```

**Why these names?** The `svc.internal` domain is a shared, cluster-neutral namespace. Neither
cluster owns it — it is a VPC-level construct managed in Cloud DNS. This is the mechanism that
makes cross-cluster service discovery possible without any cluster knowing the internal
addressing of the other.

---

## Phase 3 — kube-dns Stub Domains (dpv1 only)

> **dpv2 skips this phase entirely.** Cloud DNS VPC scope (`--cluster-dns-scope=vpc`)
> automatically resolves all private zones attached to `vpc-global` — including `svc.internal`
> — without any cluster-side configuration.

`gke-std-dpv1` uses kube-dns, which only resolves `cluster.local` natively. To resolve
external DNS suffixes (like `svc.internal` or `gke-std-dpv2.local`), kube-dns must be told
to forward those queries to an upstream resolver. This is done via the `stubDomains` field in
the `kube-dns` ConfigMap.

### Apply the ConfigMap patch

Run in **Terminal 1** (kubectl context: `gke-std-dpv1`):

```bash
kubectl apply -f kube-dns/kube-dns-stub-domains.yaml
```

The ConfigMap sets two forwarding rules:

```yaml
stubDomains: |
  {
    "gke-std-dpv2.local": ["169.254.169.254"],
    "svc.internal":       ["169.254.169.254"]
  }
```

`169.254.169.254` is GCP's VPC metadata endpoint, which also acts as the Cloud DNS VPC
resolver. It respects private zone visibility — any zone attached to `vpc-global` is
resolvable through it.

- **`svc.internal`** — enables dpv1 pods to resolve `backend-central.svc.internal` and
  `backend-west.svc.internal` (Tests 3 and 4)
- **`gke-std-dpv2.local`** — enables dpv1 pods to resolve dpv2 services by their native
  Cloud DNS VPC-scoped name, e.g. `backend.default.svc.gke-std-dpv2.local` (Test 5)

Verify the ConfigMap is active:

```bash
kubectl get configmap kube-dns -n kube-system -o yaml
```

The output should include the `stubDomains` block with both entries. Changes take effect
within a few seconds — kube-dns watches the ConfigMap and reloads automatically.

---

## Phase 4 — Cross-Cluster Firewall Rules

GKE automatically creates firewall rules that allow Internal LB health checks and traffic
from within the same cluster's node and pod CIDRs. It does **not** create rules for traffic
arriving from another cluster's pod CIDR. Without additional rules, cross-cluster HTTP calls
are dropped silently — the packet reaches the VPC but is rejected before it reaches the node.

```bash
cd cloud-dns/
./03-cross-cluster-firewall.sh
```

This creates two ingress rules on `vpc-global`:

| Rule name | Source CIDR | Destination | Port |
|---|---|---|---|
| `allow-dpv1-pods-to-dpv2-ilb` | `10.4.0.0/14` (central pods) | nodes tagged `gke-cluster` | tcp:80 |
| `allow-dpv2-pods-to-dpv1-ilb` | `10.8.0.0/14` (west pods) | nodes tagged `gke-cluster` | tcp:80 |

Both clusters were created with `--tags="gke-cluster,private-cluster"`, so the `gke-cluster`
target tag matches nodes in both clusters. Traffic is only permitted on port 80 (the ILB
listener port) — no other ports are opened between clusters.

Verify the rules were created:

```bash
gcloud compute firewall-rules list \
  --filter='name~dpv' \
  --project=PROJECT_ID \
  --format='table(name,direction,sourceRanges,targetTags,allowed)'
```

---

## Phase 5 — Run Validation Tests

With all four phases complete, run the test suite against each cluster.

### Using the automated test runner

The `run-tests.sh` script runs all tests from inside the `debug` pod in the currently active
cluster. Set `CLUSTER=dpv1` or `CLUSTER=dpv2` to control which test paths are exercised.

```bash
cd validation/

# Run against gke-std-dpv1 (Terminal 1)
CLUSTER=dpv1 bash run-tests.sh

# Run against gke-std-dpv2 (Terminal 2)
CLUSTER=dpv2 bash run-tests.sh
```

### What each test proves

#### Test 1 — In-cluster ClusterIP DNS

```
dpv1: nslookup backend.default.svc.cluster.local
dpv2: nslookup backend.default.svc.gke-std-dpv2.local
```

**What it confirms:** The cluster's own DNS resolver is operational and can resolve internal
service names. For dpv1, the resolver is kube-dns at `10.16.0.10`. For dpv2, it is the
node-local Cloud DNS stub at `169.254.20.10`.

**What to look for:**
- dpv1: response comes from `10.16.0.10`, resolved IP is in `10.16.0.0/20` (central services)
- dpv2: response comes from `169.254.20.10`, resolved IP is in `10.17.0.0/20` (west services)

#### Test 2 — In-cluster HTTP

```
dpv1: curl http://backend.default.svc.cluster.local
dpv2: curl http://backend.default.svc.gke-std-dpv2.local
```

**What it confirms:** The backend pods are healthy and serving traffic. The `whereami` JSON
response identifies the cluster, pod, and node — confirm the `cluster_name` and `metadata`
fields match the cluster you are running against.

**What to look for:**
- `cluster_name` matches the cluster context you are in
- `pod_ip` is in the expected pod CIDR (`10.4.x.x` for dpv1, `10.8.x.x` for dpv2)
- `metadata` field shows the correct cluster, region, DNS type, and subnet

#### Test 3 — Cross-cluster DNS via `svc.internal`

```
nslookup backend-central.svc.internal
nslookup backend-west.svc.internal
```

Run from **both** clusters. Both names should resolve from both clusters.

**What it confirms:**
- From dpv1: the kube-dns stub domain for `svc.internal` is forwarding to `169.254.169.254`,
  which resolves the Cloud DNS private zone records correctly
- From dpv2: Cloud DNS VPC scope is resolving the `svc.internal` zone natively with no
  ConfigMap configuration

**What to look for:**
- `backend-central.svc.internal` resolves to the dpv1 ILB IP (in `10.0.0.0/20`)
- `backend-west.svc.internal` resolves to the dpv2 ILB IP (in `10.1.0.0/20`)
- DNS answer is marked **Non-authoritative** — expected, as these records come from Cloud DNS

#### Test 4 — Cross-cluster HTTP via `svc.internal`

```
curl http://backend-central.svc.internal
curl http://backend-west.svc.internal
```

This is the headline test. Run from **both** clusters. Each call traverses the full path:
DNS resolution → VPC routing → cross-region ILB → backend pod.

**What it confirms:** End-to-end cross-cluster connectivity works — DNS, routing, ILB global
access, firewall rules, and the backend pods are all functioning correctly together.

**What to look for when calling from dpv1 (`us-central1`):**
- `curl http://backend-central.svc.internal` → response shows `cluster_name: gke-std-dpv1`
  (loopback through own ILB)
- `curl http://backend-west.svc.internal` → response shows `cluster_name: gke-std-dpv2`,
  `zone: us-west1-a` — confirms the traffic crossed regions

**What to look for when calling from dpv2 (`us-west1`):**
- `curl http://backend-central.svc.internal` → response shows `cluster_name: gke-std-dpv1`,
  `zone: us-central1-a` — confirms the traffic crossed regions
- `curl http://backend-west.svc.internal` → response shows `cluster_name: gke-std-dpv2`
  (loopback through own ILB)

#### Test 5 — kube-dns stub domain resolves dpv2 Cloud DNS name (dpv1 only)

```
nslookup backend.default.svc.gke-std-dpv2.local
```

Run from **dpv1 only**. This test is automatically skipped when `CLUSTER=dpv2`.

**What it confirms:** The kube-dns stub domain for `gke-std-dpv2.local` is correctly
forwarding to `169.254.169.254`, which resolves the VPC-scoped Cloud DNS zone for dpv2.

**What to look for:**
- Resolved IP is in `10.17.0.0/20` (dpv2 west services CIDR)
- This is a ClusterIP — a Kubernetes-internal virtual IP that only exists inside kube-proxy
  on dpv2's nodes. It is **not** routable across the VPC. A successful DNS resolution to the
  correct CIDR range is the complete proof. Cross-cluster HTTP is validated via the ILB in
  Test 4.

### Manual validation commands

For ad-hoc investigation and step-by-step verification, all individual commands are documented
in `validation/validation-commands.md`.

To run any command manually from inside the debug pod:

```bash
kubectl exec -it debug -- <command>

# Examples:
kubectl exec -it debug -- nslookup backend-central.svc.internal
kubectl exec -it debug -- curl -s http://backend-west.svc.internal
kubectl exec -it debug -- dig @169.254.20.10 backend.default.svc.gke-std-dpv2.local
kubectl exec -it debug -- cat /etc/resolv.conf
```

---

## Teardown

To remove all Kubernetes resources from both clusters:

```bash
# Terminal 1 — gke-std-dpv1
kubectl delete -f dpv1/backend-deployment.yaml
kubectl delete -f dpv1/backend-svc-clusterip.yaml
kubectl delete -f dpv1/backend-svc-ilb.yaml
kubectl delete -f validation/debug-pod.yaml

# Terminal 2 — gke-std-dpv2
kubectl delete -f dpv2/backend-deployment.yaml
kubectl delete -f dpv2/backend-svc-clusterip.yaml
kubectl delete -f dpv2/backend-svc-ilb.yaml
kubectl delete -f validation/debug-pod.yaml
```

To remove the Cloud DNS zone and firewall rules:

```bash
# Delete A records first, then the zone
gcloud dns record-sets delete backend-central.svc.internal. \
  --zone=svc-internal --type=A --project=PROJECT_ID

gcloud dns record-sets delete backend-west.svc.internal. \
  --zone=svc-internal --type=A --project=PROJECT_ID

gcloud dns managed-zones delete svc-internal --project=PROJECT_ID

# Delete cross-cluster firewall rules
gcloud compute firewall-rules delete allow-dpv1-pods-to-dpv2-ilb --project=PROJECT_ID
gcloud compute firewall-rules delete allow-dpv2-pods-to-dpv1-ilb --project=PROJECT_ID
```

To revert the kube-dns ConfigMap on dpv1:

```bash
# Terminal 1 — gke-std-dpv1
kubectl patch configmap kube-dns -n kube-system --type=json \
  -p='[{"op": "remove", "path": "/data/stubDomains"}]'
```
