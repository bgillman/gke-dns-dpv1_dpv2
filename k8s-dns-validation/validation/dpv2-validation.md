# dpv2 Validation — Full Pass

**Cluster:** `gke-std-dpv2`
**Region:** `us-west1-a`
**DNS Provider:** Cloud DNS (`gke-std-dpv2.local`, VPC scope)
**Dataplane:** V2 (eBPF-based CNI with metrics and flow observability)
**Node Subnet:** `west-vpc-subnet-01` (`10.1.0.0/20`)
**Pod CIDR:** `10.8.0.0/14`
**Service CIDR:** `10.17.0.0/20`

---

## Key Difference vs. dpv1

The resolver address across all dpv2 responses is `169.254.20.10` — not a
Kubernetes ClusterIP like dpv1's kube-dns at `10.16.0.10`. On dpv2, GKE
deploys a **node-local Cloud DNS stub resolver** at this link-local address
on every node. All pod DNS queries hit this local stub first, which forwards
to Cloud DNS managed zones. It is not a Kubernetes Service and does not appear
in `kubectl get svc`.

A second major difference: the `svc.internal` private zone (Test 3) resolves
on dpv2 with **zero ConfigMap configuration**. Cloud DNS VPC scope
automatically resolves all private zones attached to `vpc-global`. On dpv1,
this required an explicit `kube-dns` ConfigMap stub domain patch.

| Property | gke-std-dpv1 | gke-std-dpv2 |
|---|---|---|
| DNS resolver address | `10.16.0.10` (kube-dns ClusterIP) | `169.254.20.10` (node-local Cloud DNS stub) |
| Cluster DNS domain | `cluster.local` | `gke-std-dpv2.local` |
| `svc.internal` resolution | Requires kube-dns stub domain ConfigMap patch | Native — no config needed |
| Cross-cluster domain forwarding | Manual stub domain per domain suffix | Automatic via VPC scope |

---

## Node-Local Cloud DNS Stub — `169.254.20.10`

### What is it?

It is **not a pod**. It is not a Kubernetes Service, Deployment, or DaemonSet. It
is a **per-node OS-level process** — a lightweight DNS stub resolver daemon that
GKE injects and manages directly on each node's host network stack as part of
node bootstrap, outside the Kubernetes control plane entirely.

### How it works

When a GKE cluster is created with `--cluster-dns=clouddns`, GKE's node
bootstrap process installs a stub resolver process on every node. This process:

1. **Binds to the link-local address `169.254.20.10:53`** on a loopback-like
   interface that is only reachable within that node. Link-local addresses
   (`169.254.0.0/16`) are never routed — they are strictly per-host, so this
   address is the same on every node in the cluster without conflict.

2. **Is managed by systemd** (or the node init system), not by the Kubernetes
   control plane. You will not find it with `kubectl get pods --all-namespaces`.

3. **Acts as a forwarding stub** — it holds no zone database. When a pod sends
   a DNS query, the stub receives it, forwards it to **Cloud DNS's VPC resolver
   at `169.254.169.254`**, and returns the answer to the pod. The round-trip
   stays within Google's internal network fabric and never leaves the VPC.

4. **Intercepts the query before it leaves the node**, which eliminates the
   network hop to a centralized `kube-dns` pod running elsewhere in the cluster.
   This is the primary performance and availability advantage over kube-dns.

Because the address is hardcoded, every pod's `/etc/resolv.conf` is configured
identically at cluster creation time — every pod on every node points to the
same link-local address, and each node's local stub handles it locally.

### Architecture comparison

| Layer | kube-dns (dpv1) | Cloud DNS stub (dpv2) |
|---|---|---|
| What it is | Kubernetes Deployment (2–3 pods) | OS-level daemon per node |
| Where it runs | In pods, scheduled by kube-scheduler | On host network, outside Kubernetes |
| Address | ClusterIP (e.g. `10.16.0.10`) — virtual IP backed by kube-proxy | Link-local `169.254.20.10` — bound directly on the node |
| Managed by | Kubernetes (GKE add-on) | GKE node bootstrap / systemd |
| Visible in `kubectl` | Yes — `kubectl get svc kube-dns -n kube-system` | No |
| Blast radius of failure | Cluster-wide — if both replicas go down, all pods lose DNS | Single node only — a crash affects only pods on that node |
| Forwarding target | Resolves `cluster.local` itself; stubs to `169.254.169.254` for external zones | Always forwards to `169.254.169.254` (Cloud DNS VPC resolver) |

---

## Test Results

### TEST 1 — In-cluster ClusterIP DNS ✅

**Query:** `backend.default.svc.gke-std-dpv2.local`
**Resolver:** `169.254.20.10` (GKE node-local Cloud DNS stub)
**Result:** `10.17.11.113`

Cloud DNS resolved the cluster's own service domain natively. `10.17.11.113`
is in the west services CIDR (`10.17.0.0/20`). The cluster DNS domain
`gke-std-dpv2.local` was set at cluster creation with
`--cluster-dns-domain=gke-std-dpv2.local`. The "recursion not available"
message is consistent with dpv1 — Cloud DNS, like kube-dns, does not
advertise open recursion.

Note: the response is marked **Non-authoritative** even for the cluster's own
domain. This is expected — Cloud DNS is a managed service, not a traditional
authoritative nameserver. In contrast, kube-dns on dpv1 returns authoritative
answers for `cluster.local`.

```
Server:         169.254.20.10
Address:        169.254.20.10#53

Non-authoritative answer:
Name:   backend.default.svc.gke-std-dpv2.local
Address: 10.17.11.113
;; Got recursion not available from 169.254.20.10
```

#### Manual Validation Commands

**Confirm the node-local Cloud DNS stub is the resolver (not a kube-dns Service):**

```bash
# Should return no results — 169.254.20.10 is not a Kubernetes Service
kubectl get svc -n kube-system | grep -i dns

# Confirm no kube-dns deployment exists on this cluster
kubectl get deployment -n kube-system kube-dns 2>&1 || echo "kube-dns not present — expected on Cloud DNS cluster"
```

**Confirm the backend Service ClusterIP matches the resolved address:**

```bash
# Should return 10.17.11.113 — exactly what nslookup resolved to
kubectl get svc backend -o jsonpath='{.spec.clusterIP}{"\n"}'

# Cross-reference: confirm that IP is within the cluster's service CIDR
gcloud container clusters describe gke-std-dpv2 \
  --region=us-west1 \
  --project=gillman-gke-dns \
  --format='value(servicesIpv4Cidr)'
```

**Confirm the cluster DNS domain and Cloud DNS configuration:**

```bash
gcloud container clusters describe gke-std-dpv2 \
  --region=us-west1 \
  --project=gillman-gke-dns \
  --format='table(
    networkConfig.dnsConfig.clusterDns,
    networkConfig.dnsConfig.clusterDnsScope,
    networkConfig.dnsConfig.clusterDnsDomain
  )'
```

**Inspect the search domains and nameserver configured inside the pod:**

```bash
# Shows: nameserver 169.254.20.10 (node-local Cloud DNS stub)
# and search domains using gke-std-dpv2.local instead of cluster.local
kubectl exec -it debug -- cat /etc/resolv.conf
```

**Query the Cloud DNS stub directly with dig — shows full DNS response flags:**

```bash
# Full response including flags — note "aa" (authoritative) and "ra" (recursion available) are both absent
kubectl exec -it debug -- dig @169.254.20.10 backend.default.svc.gke-std-dpv2.local

# Short form — just the answer section
kubectl exec -it debug -- dig @169.254.20.10 backend.default.svc.gke-std-dpv2.local +short

# Confirm short-name resolution works via search domain expansion
kubectl exec -it debug -- dig @169.254.20.10 backend.default.svc +short
kubectl exec -it debug -- dig @169.254.20.10 backend.default +short
kubectl exec -it debug -- dig @169.254.20.10 backend +short
```

Reading the `dig` flags line for Cloud DNS responses:

| Flag | Meaning |
|------|---------|
| `qr` | Query Response — this is a response packet |
| `aa` | Authoritative Answer — **absent** in Cloud DNS responses; Cloud DNS is a managed service, not a traditional authoritative nameserver. kube-dns on dpv1 returns `aa` for `cluster.local`; Cloud DNS does not, even for its own cluster zones |
| `rd` | Recursion Desired — the client requested recursion |
| `ra` | Recursion Available — **absent**; the node-local Cloud DNS stub does not offer open recursion |

**Prove "recursion not available" is intentional — not an error:**

```bash
# Cloud DNS stub does not offer open recursion — returns SERVFAIL or
# "recursion not available" for external names not in managed zones
kubectl exec -it debug -- dig @169.254.20.10 google.com

# Contrast: query the GCP metadata resolver directly — this WILL recurse
kubectl exec -it debug -- dig @169.254.169.254 google.com +short
```

**Confirm the Service has the expected endpoints (pods backing it):**

```bash
# Should show 3 pod IPs in the 10.8.x.x range (west pods CIDR 10.8.0.0/14)
kubectl get endpoints backend

# More detail — shows which node each endpoint pod is on
kubectl describe endpoints backend
```

---

### TEST 2 — In-cluster HTTP (whereami) ✅

**Query:** `curl http://backend.default.svc.gke-std-dpv2.local`

`whereami` is healthy and cluster identity confirmed. `pod_ip: 10.8.2.16` is
in the west pods CIDR (`10.8.0.0/14`). The `METADATA` env var correctly
identifies the cluster, region, DNS provider, and subnet.

```json
{
    "cluster_name": "gke-std-dpv2",
    "gce_instance_id": "8902334156654083228",
    "gce_service_account": "gillman-gke-dns.svc.id.goog",
    "host_header": "backend.default.svc.gke-std-dpv2.local",
    "metadata": "cluster=gke-std-dpv2 | region=us-west1 | dns=cloud-dns | subnet=west-vpc-subnet-01",
    "node_name": "gke-gke-std-dpv2-default-pool-43ae0171-2h1f",
    "pod_ip": "10.8.2.16",
    "pod_name": "backend-559b8899d4-wr4gc",
    "pod_namespace": "default",
    "project_id": "gillman-gke-dns",
    "timestamp": "2026-02-24T21:48:20",
    "zone": "us-west1-a"
}
```

#### Manual Validation Commands

```bash
# Direct HTTP call from inside the debug pod
kubectl exec -it debug -- curl -s http://backend.default.svc.gke-std-dpv2.local

# Confirm deployment and pod status
kubectl get deployment backend
kubectl get pods -l app=backend -o wide
```

---

### TEST 3 — Cross-cluster DNS via Cloud DNS private zone (`svc.internal`) ✅

Both records resolved via `169.254.20.10` with no ConfigMap configuration.
Cloud DNS VPC scope (`--cluster-dns-scope=vpc`) makes all private zones
attached to `vpc-global` — including `svc.internal` — automatically
resolvable from pods in this cluster. This is the core advantage of Cloud DNS
VPC scope over kube-dns, which required an explicit stub domain entry for
each zone suffix.

**Query:** `backend-central.svc.internal`
**Expected:** dpv1 ILB IP (`10.0.x.x`)
**Result:** `10.0.0.11` ✅

```
Server:         169.254.20.10
Address:        169.254.20.10#53

Non-authoritative answer:
Name:   backend-central.svc.internal
Address: 10.0.0.11
;; Got recursion not available from 169.254.20.10
```

**Query:** `backend-west.svc.internal`
**Expected:** dpv2 ILB IP (`10.1.x.x`)
**Result:** `10.1.0.6` ✅

```
Server:         169.254.20.10
Address:        169.254.20.10#53

Non-authoritative answer:
Name:   backend-west.svc.internal
Address: 10.1.0.6
;; Got recursion not available from 169.254.20.10
```

#### Manual Validation Commands

**Confirm the Cloud DNS private zone exists and is scoped to vpc-global:**

```bash
gcloud dns managed-zones describe svc-internal \
  --project=gillman-gke-dns \
  --format='table(name,dnsName,visibility,privateVisibilityConfig.networks[].networkUrl)'
```

**List all records in the private zone:**

```bash
gcloud dns record-sets list \
  --zone=svc-internal \
  --project=gillman-gke-dns
```

**Manually resolve both A records from inside the debug pod:**

```bash
# dpv1 ILB — expected: 10.0.0.11
kubectl exec -it debug -- nslookup backend-central.svc.internal

# dpv2 ILB — expected: 10.1.0.6
kubectl exec -it debug -- nslookup backend-west.svc.internal

# Using dig for full response detail
kubectl exec -it debug -- dig backend-central.svc.internal +short
kubectl exec -it debug -- dig backend-west.svc.internal +short
```

**Confirm no ConfigMap patch exists on this cluster (resolution is fully native):**

```bash
# Should show an empty data section — no stubDomains configured
kubectl get configmap kube-dns -n kube-system -o yaml 2>&1 || \
  echo "kube-dns ConfigMap not present — expected on Cloud DNS cluster"
```

---

### TEST 4 — Cross-cluster HTTP via `svc.internal` ✅

The symmetric counterpart to dpv1's Test 4. Two HTTP calls, two different
clusters responding, with the cross-region path now originating from
`us-west1` (dpv2) instead of `us-central1` (dpv1).

**`backend-central.svc.internal` → dpv1 (cross-region)** ✅

Full cross-region path confirmed: dpv2 pod (`us-west1`) → Cloud DNS VPC scope
→ `svc.internal` A record → dpv1 Internal LB (`us-central1`, global access
enabled) → dpv1 backend pod. `pod_ip: 10.4.2.4` is in the central pods CIDR
(`10.4.0.0/14`). `zone: us-central1-a` confirms the response originated from
the remote region.

```json
{
    "cluster_name": "gke-std-dpv1",
    "gce_instance_id": "8055427349605319570",
    "gce_service_account": "gillman-gke-dns.svc.id.goog",
    "host_header": "backend-central.svc.internal",
    "metadata": "cluster=gke-std-dpv1 | region=us-central1 | dns=kube-dns | subnet=central-vpc-subnet-01",
    "node_name": "gke-gke-std-dpv1-default-pool-0e33703d-60j4",
    "pod_ip": "10.4.2.4",
    "pod_name": "backend-666dbfc8bb-fwssj",
    "pod_namespace": "default",
    "project_id": "gillman-gke-dns",
    "timestamp": "2026-02-24T21:48:23",
    "zone": "us-central1-a"
}
```

**`backend-west.svc.internal` → dpv2 (loopback via own ILB)** ✅

```json
{
    "cluster_name": "gke-std-dpv2",
    "gce_instance_id": "2816013345263549596",
    "gce_service_account": "gillman-gke-dns.svc.id.goog",
    "host_header": "backend-west.svc.internal",
    "metadata": "cluster=gke-std-dpv2 | region=us-west1 | dns=cloud-dns | subnet=west-vpc-subnet-01",
    "node_name": "gke-gke-std-dpv2-default-pool-43ae0171-340s",
    "pod_ip": "10.8.0.5",
    "pod_name": "backend-559b8899d4-hbm5x",
    "pod_namespace": "default",
    "project_id": "gillman-gke-dns",
    "timestamp": "2026-02-24T21:48:24",
    "zone": "us-west1-a"
}
```

#### Manual Validation Commands

**Confirm both ILB services have assigned IPs:**

```bash
# Get just the assigned IP
kubectl get svc backend-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'

# Full service detail
kubectl get svc backend-ilb -o wide
```

**Confirm global access is enabled on the ILB:**

```bash
kubectl get svc backend-ilb -o jsonpath='{.metadata.annotations}{"\n"}'
```

**Confirm cross-cluster firewall rules exist:**

```bash
gcloud compute firewall-rules list \
  --filter='name~dpv' \
  --project=gillman-gke-dns \
  --format='table(name,direction,sourceRanges,targetTags,allowed)'
```

**Manual HTTP calls from the debug pod:**

```bash
# Should return whereami JSON with cluster_name: gke-std-dpv1
kubectl exec -it debug -- curl -s http://backend-central.svc.internal

# Should return whereami JSON with cluster_name: gke-std-dpv2
kubectl exec -it debug -- curl -s http://backend-west.svc.internal
```

---

## Summary

| Test | Description | Result |
|------|-------------|--------|
| 1 | In-cluster DNS — `gke-std-dpv2.local` via Cloud DNS stub | ✅ Pass |
| 2 | In-cluster HTTP — `whereami` cluster identity | ✅ Pass |
| 3a | Cross-cluster DNS — `backend-central.svc.internal` | ✅ Pass |
| 3b | Cross-cluster DNS — `backend-west.svc.internal` | ✅ Pass |
| 4a | Cross-cluster HTTP — dpv1 ILB (cross-region) | ✅ Pass |
| 4b | Cross-cluster HTTP — dpv2 ILB (loopback) | ✅ Pass |

---

## Notable Observations

**No ConfigMap patch required.** Unlike dpv1 which needed a `kube-dns`
ConfigMap stub domain entry for each external DNS suffix (`svc.internal`,
`gke-std-dpv2.local`), dpv2 resolved all private zones in `vpc-global`
automatically. This is the operational benefit of Cloud DNS VPC scope — any
new private zone added to the VPC is immediately resolvable from dpv2 pods
without any cluster-side configuration changes.

**Node-local resolver architecture.** The `169.254.20.10` resolver is a
per-node stub process managed by GKE, not a cluster-wide Service. This
improves DNS performance by eliminating the network hop to a centralized
kube-dns pod and reduces blast radius — a resolver failure is isolated to a
single node rather than affecting the entire cluster.

**Consistent cross-region behavior.** Both dpv1 and dpv2 successfully
performed cross-region HTTP calls via the `svc.internal` private zone,
confirming that ILB global access combined with `vpc-global`'s GLOBAL routing
mode provides symmetric, bidirectional cross-cluster reachability.
