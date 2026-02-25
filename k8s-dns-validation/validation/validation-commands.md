# Manual Validation Commands — kube-dns / Cloud DNS

Reference commands for manually validating DNS behavior across `gke-std-dpv1`
(kube-dns) and `gke-std-dpv2` (Cloud DNS). Organized by what each command
confirms.

---

## TEST 1 — In-cluster kube-dns (`cluster.local`)

### Confirm kube-dns is the active resolver and its ClusterIP matches

```bash
# Should show ClusterIP = 10.16.0.10 — the resolver reported in the nslookup output
kubectl get svc kube-dns -n kube-system -o wide

# Confirm kube-dns pods are running and on which nodes
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
```

### Confirm the backend Service ClusterIP matches the resolved address

```bash
# Should return 10.16.6.159 — exactly what nslookup resolved to
kubectl get svc backend -o jsonpath='{.spec.clusterIP}{"\n"}'

# Cross-reference: confirm that IP is within the cluster's service CIDR
gcloud container clusters describe gke-std-dpv1 \
  --region=us-central1 \
  --project=gillman-gke-dns \
  --format='value(servicesIpv4Cidr)'
```

### Inspect the search domains and nameserver configured inside the pod

```bash
# Shows: nameserver 10.16.0.10 (kube-dns) and search domains
# e.g. default.svc.cluster.local  svc.cluster.local  cluster.local
kubectl exec -it debug -- cat /etc/resolv.conf
```

### Query kube-dns directly with dig — shows full DNS response flags

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

### Prove "recursion not available" is intentional — not an error

kube-dns does not support open recursion. External names are handled via
forwarding rules (stub domains), not recursive resolution. The absence of
the `ra` (recursion available) flag in the DNS response flags is by design.

```bash
# Ask kube-dns to recursively resolve an external name.
# Returns SERVFAIL or "recursion not available" — expected behavior.
kubectl exec -it debug -- dig @10.16.0.10 google.com

# Contrast: query the GCP Cloud DNS resolver directly — this WILL recurse.
kubectl exec -it debug -- dig @169.254.169.254 google.com +short
```

**Reading the dig flags line:**

| Flag | Meaning |
|------|---------|
| `qr` | Query Response — this is a response packet |
| `aa` | Authoritative Answer — kube-dns owns `cluster.local` |
| `rd` | Recursion Desired — the client requested recursion |
| `ra` | Recursion Available — **absent** in kube-dns responses, confirming it does not offer open recursion |

### Confirm stub domains are live in the kube-dns ConfigMap

```bash
# Should show the stubDomains block with gke-std-dpv2.local and svc.internal
# both pointing to 169.254.169.254
kubectl get configmap kube-dns -n kube-system -o yaml
```

### Confirm the Service has the expected endpoints (pods backing it)

```bash
# Should show 3 pod IPs in the 10.4.x.x range (central pods CIDR 10.4.0.0/14)
kubectl get endpoints backend

# More detail — shows which node each endpoint pod is on
kubectl describe endpoints backend
```

---

## TEST 3 — Cross-cluster DNS via Cloud DNS private zone (`svc.internal`)

### Confirm the Cloud DNS private zone exists and is scoped to vpc-global

```bash
gcloud dns managed-zones describe svc-internal \
  --project=gillman-gke-dns \
  --format='table(name,dnsName,visibility,privateVisibilityConfig.networks[].networkUrl)'
```

### List all records in the private zone

```bash
gcloud dns record-sets list \
  --zone=svc-internal \
  --project=gillman-gke-dns
```

### Manually resolve both A records from inside the debug pod

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

## TEST 4 — Cross-cluster HTTP via `svc.internal`

### Confirm both ILB services have assigned IPs (not pending)

```bash
# Run in each cluster's terminal window
kubectl get svc backend-ilb -o wide

# Get just the IP
kubectl get svc backend-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
```

### Confirm global access is enabled on the ILB

```bash
# Run in each cluster's terminal window
kubectl get svc backend-ilb -o jsonpath='{.metadata.annotations}{"\n"}'
```

### Confirm cross-cluster firewall rules exist

```bash
gcloud compute firewall-rules list \
  --filter='name~dpv' \
  --project=gillman-gke-dns \
  --format='table(name,direction,sourceRanges,targetTags,allowed)'
```

### Manual HTTP calls from the debug pod

```bash
# Should return whereami JSON with cluster_name: gke-std-dpv1
kubectl exec -it debug -- curl -s http://backend-central.svc.internal

# Should return whereami JSON with cluster_name: gke-std-dpv2
kubectl exec -it debug -- curl -s http://backend-west.svc.internal
```

---

## TEST 5 — kube-dns stub domain resolves dpv2 native Cloud DNS name

### Confirm the stub domain is forwarding correctly

```bash
# Should resolve to a ClusterIP in 10.17.x.x (west services CIDR 10.17.0.0/20)
# Resolution proves the stub domain forwarded the query to 169.254.169.254
# and Cloud DNS returned the VPC-scoped record for gke-std-dpv2.local
kubectl exec -it debug -- nslookup backend.default.svc.gke-std-dpv2.local

# Full dig output — nameserver in the response will be 169.254.169.254, not
# 10.16.0.10, confirming the query left kube-dns via the stub domain
kubectl exec -it debug -- dig backend.default.svc.gke-std-dpv2.local
```

### Cross-reference: confirm the resolved IP is the actual dpv2 service ClusterIP

```bash
# Run in Terminal 2 (gke-std-dpv2 context) — should match what nslookup returned
kubectl get svc backend -o jsonpath='{.spec.clusterIP}{"\n"}'

# Confirm that IP is in the west services CIDR
gcloud container clusters describe gke-std-dpv2 \
  --region=us-west1 \
  --project=gillman-gke-dns \
  --format='value(servicesIpv4Cidr)'
```
