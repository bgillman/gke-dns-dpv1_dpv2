# dpv1 Validation — Full Pass

**Cluster:** `gke-std-dpv1`
**Region:** `us-central1-a`
**DNS Provider:** kube-dns (`cluster.local`)
**Dataplane:** V1 (Legacy CNI / standard kube-proxy)
**Node Subnet:** `central-vpc-subnet-01` (`10.0.0.0/20`)
**Pod CIDR:** `10.4.0.0/14`
**Service CIDR:** `10.16.0.0/20`

---

## Test Results

### TEST 1 — In-cluster ClusterIP DNS ✅

**Query:** `backend.default.svc.cluster.local`
**Resolver:** `10.16.0.10` (kube-dns ClusterIP)
**Result:** `10.16.6.159`

kube-dns is serving `cluster.local` internally. `10.16.6.159` is in the
central services CIDR (`10.16.0.0/20`). The "recursion not available" message
is informational — kube-dns intentionally disables recursion from external
resolvers by design.

```
Server:         10.16.0.10
Address:        10.16.0.10#53

Name:   backend.default.svc.cluster.local
Address: 10.16.6.159
;; Got recursion not available from 10.16.0.10
```

#### Manual Validation Commands

**Confirm kube-dns is the active resolver and its ClusterIP matches:**

```bash
# Should show ClusterIP = 10.16.0.10 — the resolver reported in the nslookup output
kubectl get svc kube-dns -n kube-system -o wide

# Confirm kube-dns pods are running and on which nodes
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
```

**Confirm the backend Service ClusterIP matches the resolved address:**

```bash
# Should return 10.16.6.159 — exactly what nslookup resolved to
kubectl get svc backend -o jsonpath='{.spec.clusterIP}{"\n"}'

# Cross-reference: confirm that IP is within the cluster's service CIDR
gcloud container clusters describe gke-std-dpv1 \
  --region=us-central1 \
  --project=gillman-gke-dns \
  --format='value(servicesIpv4Cidr)'
```

**Inspect the search domains and nameserver configured inside the pod:**

```bash
# Shows: nameserver 10.16.0.10 (kube-dns) and search domains
# e.g. default.svc.cluster.local  svc.cluster.local  cluster.local
kubectl exec -it debug -- cat /etc/resolv.conf
```

**Query kube-dns directly with dig — shows full DNS response flags:**

```bash
# Full response including flags — look for "qr aa" (authoritative answer)
# and absence of "ra" (recursion available)
kubectl exec -it debug -- dig @10.16.0.10 backend.default.svc.cluster.local

# Short form — just the answer section
kubectl exec -it debug -- dig @10.16.0.10 backend.default.svc.cluster.local +short

# Confirm short-name resolution works via search domain expansion
kubectl exec -it debug -- dig @10.16.0.10 backend.default.svc +short
kubectl exec -it debug -- dig @10.16.0.10 backend.default +short
kubectl exec -it debug -- dig @10.16.0.10 backend +short
```

**Prove "recursion not available" is intentional — not an error:**

```bash
# Ask kube-dns to recursively resolve an external name.
# Returns SERVFAIL or "recursion not available" — expected behavior.
kubectl exec -it debug -- dig @10.16.0.10 google.com

# Contrast: query the GCP Cloud DNS resolver directly — this WILL recurse.
kubectl exec -it debug -- dig @169.254.169.254 google.com +short
```

Reading the `dig` flags line:

| Flag | Meaning |
|------|---------|
| `qr` | Query Response — this is a response packet |
| `aa` | Authoritative Answer — kube-dns owns `cluster.local` |
| `rd` | Recursion Desired — the client requested recursion |
| `ra` | Recursion Available — **absent** in kube-dns responses, confirming it does not offer open recursion |

**Confirm stub domains are live in the kube-dns ConfigMap:**

```bash
# Should show the stubDomains block with gke-std-dpv2.local and svc.internal
# both pointing to 169.254.169.254
kubectl get configmap kube-dns -n kube-system -o yaml
```

**Confirm the Service has the expected endpoints (pods backing it):**

```bash
# Should show 3 pod IPs in the 10.4.x.x range (central pods CIDR 10.4.0.0/14)
kubectl get endpoints backend

# More detail — shows which node each endpoint pod is on
kubectl describe endpoints backend
```

---

### TEST 2 — In-cluster HTTP (whereami) ✅

**Query:** `curl http://backend.default.svc.cluster.local`

`whereami` is healthy and cluster identity is confirmed. `pod_ip: 10.4.0.14`
falls in the central pods CIDR (`10.4.0.0/14`). The `METADATA` env var is
correctly embedded in every response.

```json
{
    "cluster_name": "gke-std-dpv1",
    "gce_instance_id": "5722131368997094290",
    "gce_service_account": "gillman-gke-dns.svc.id.goog",
    "host_header": "backend.default.svc.cluster.local",
    "metadata": "cluster=gke-std-dpv1 | region=us-central1 | dns=kube-dns | subnet=central-vpc-subnet-01",
    "node_name": "gke-gke-std-dpv1-default-pool-0e33703d-cgcg",
    "pod_ip": "10.4.0.14",
    "pod_name": "backend-666dbfc8bb-8k7zw",
    "pod_namespace": "default",
    "project_id": "gillman-gke-dns",
    "timestamp": "2026-02-23T23:12:13",
    "zone": "us-central1-a"
}
```

#### Manual Validation Commands

```bash
# Direct HTTP call from inside the debug pod
kubectl exec -it debug -- curl -s http://backend.default.svc.cluster.local

# Confirm deployment and pod status
kubectl get deployment backend
kubectl get pods -l app=backend -o wide
```

---

### TEST 3 — Cross-cluster DNS via Cloud DNS private zone (`svc.internal`) ✅

The kube-dns stub domain for `svc.internal` forwards to `169.254.169.254`
(GCP's Cloud DNS resolver). Both A records in the `svc.internal` private zone
resolve correctly from inside dpv1 without any native Cloud DNS configuration
on this cluster.

**Query:** `backend-central.svc.internal`
**Expected:** dpv1 ILB IP (`10.0.x.x`)
**Result:** `10.0.0.11` ✅

```
Server:         10.16.0.10
Address:        10.16.0.10#53

Non-authoritative answer:
Name:   backend-central.svc.internal
Address: 10.0.0.11
```

**Query:** `backend-west.svc.internal`
**Expected:** dpv2 ILB IP (`10.1.x.x`)
**Result:** `10.1.0.6` ✅

```
Server:         10.16.0.10
Address:        10.16.0.10#53

Non-authoritative answer:
Name:   backend-west.svc.internal
Address: 10.1.0.6
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

---

### TEST 4 — Cross-cluster HTTP via `svc.internal` ✅

The headline result. Two HTTP calls, two different clusters responding.

**`backend-central.svc.internal` → dpv1 (loopback via own ILB)** ✅

```json
{
    "cluster_name": "gke-std-dpv1",
    "gce_instance_id": "6907592701184639890",
    "gce_service_account": "gillman-gke-dns.svc.id.goog",
    "host_header": "backend-central.svc.internal",
    "metadata": "cluster=gke-std-dpv1 | region=us-central1 | dns=kube-dns | subnet=central-vpc-subnet-01",
    "node_name": "gke-gke-std-dpv1-default-pool-0e33703d-8kpj",
    "pod_ip": "10.4.1.4",
    "pod_name": "backend-666dbfc8bb-v5fzz",
    "pod_namespace": "default",
    "project_id": "gillman-gke-dns",
    "timestamp": "2026-02-23T23:12:15",
    "zone": "us-central1-a"
}
```

**`backend-west.svc.internal` → dpv2 (cross-region, cross-cluster)** ✅

Full cross-region path confirmed: dpv1 pod (`us-central1`) → Cloud DNS stub
domain → `svc.internal` A record → dpv2 Internal LB (`us-west1`, global access
enabled) → dpv2 backend pod. The `host_header: "backend-west.svc.internal"`
in the response confirms the DNS name (not a raw IP) traversed the full path.
`pod_ip: 10.8.2.16` is in the west pods CIDR (`10.8.0.0/14`).

```json
{
    "cluster_name": "gke-std-dpv2",
    "gce_instance_id": "8902334156654083228",
    "gce_service_account": "gillman-gke-dns.svc.id.goog",
    "host_header": "backend-west.svc.internal",
    "metadata": "cluster=gke-std-dpv2 | region=us-west1 | dns=cloud-dns | subnet=west-vpc-subnet-01",
    "node_name": "gke-gke-std-dpv2-default-pool-43ae0171-2h1f",
    "pod_ip": "10.8.2.16",
    "pod_name": "backend-559b8899d4-wr4gc",
    "pod_namespace": "default",
    "project_id": "gillman-gke-dns",
    "timestamp": "2026-02-23T23:12:27",
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

### TEST 5 — kube-dns stub domain resolves dpv2 native Cloud DNS name ✅

**Query:** `backend.default.svc.gke-std-dpv2.local`
**Expected:** dpv2 ClusterIP (`10.17.x.x`)
**Result:** `10.17.11.113` ✅

The kube-dns stub domain for `gke-std-dpv2.local` forwards to
`169.254.169.254`, which resolves the query from dpv2's Cloud DNS VPC-scoped
zone. `10.17.11.113` is in the west services CIDR (`10.17.0.0/20`), confirming
the answer came from the correct zone.

Note: A ClusterIP is a Kubernetes-internal virtual IP that only exists inside
kube-proxy on dpv2's nodes. It is not routable across the VPC by design.
DNS resolution to the correct CIDR range is the complete proof for this test.
HTTP cross-cluster traffic is validated via the ILB in Test 4.

```
Server:         10.16.0.10
Address:        10.16.0.10#53

Non-authoritative answer:
Name:   backend.default.svc.gke-std-dpv2.local
Address: 10.17.11.113
```

#### Manual Validation Commands

**Confirm the stub domain is forwarding correctly:**

```bash
# Should resolve to a ClusterIP in 10.17.x.x (west services CIDR 10.17.0.0/20)
kubectl exec -it debug -- nslookup backend.default.svc.gke-std-dpv2.local

# Full dig output — nameserver in the response will be 169.254.169.254, not
# 10.16.0.10, confirming the query left kube-dns via the stub domain
kubectl exec -it debug -- dig backend.default.svc.gke-std-dpv2.local
```

**Cross-reference: confirm the resolved IP is the actual dpv2 service ClusterIP:**

```bash
# Run in Terminal 2 (gke-std-dpv2 context) — should match what nslookup returned
kubectl get svc backend -o jsonpath='{.spec.clusterIP}{"\n"}'

# Confirm that IP is in the west services CIDR
gcloud container clusters describe gke-std-dpv2 \
  --region=us-west1 \
  --project=gillman-gke-dns \
  --format='value(servicesIpv4Cidr)'
```

---

## Summary

| Test | Description | Result |
|------|-------------|--------|
| 1 | In-cluster DNS — `cluster.local` via kube-dns | ✅ Pass |
| 2 | In-cluster HTTP — `whereami` cluster identity | ✅ Pass |
| 3a | Cross-cluster DNS — `backend-central.svc.internal` | ✅ Pass |
| 3b | Cross-cluster DNS — `backend-west.svc.internal` | ✅ Pass |
| 4a | Cross-cluster HTTP — dpv1 ILB (loopback) | ✅ Pass |
| 4b | Cross-cluster HTTP — dpv2 ILB (cross-region) | ✅ Pass |
| 5 | kube-dns stub domain → Cloud DNS (`gke-std-dpv2.local`) | ✅ Pass |

---

## Issues Encountered and Resolved

**1. Pod CIDR conflict on cluster creation**
The cluster creation script passed `--cluster-ipv4-cidr` with a CIDR already
allocated as a named secondary range by Terraform. Fixed by replacing
`--cluster-ipv4-cidr` with `--cluster-secondary-range-name` and adding
`--services-secondary-range-name` to reference the pre-existing ranges by name.

**2. Control plane public IP**
The original script included `--enable-ip-access`, which caused GKE to assign
a public IP to the control plane. Fixed by replacing with `--no-enable-ip-access`
and removing master authorized network flags. Access is exclusively via the
GKE DNS-based endpoint (`--enable-dns-access`).

**3. Internal LB cross-region timeout**
HTTP calls to `backend-west.svc.internal` (`10.1.0.6`) timed out despite
correct DNS resolution. Root cause: GCP Internal Passthrough NLBs are regional
by default. Traffic from `us-central1` (dpv1 pods) to a `us-west1` ILB is
blocked at the load balancer level before firewall rules are evaluated. Fixed
by adding `networking.gke.io/internal-load-balancer-allow-global-access: "true"`
to both ILB Service manifests.
