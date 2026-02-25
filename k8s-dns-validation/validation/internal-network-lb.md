# Internal Network Passthrough Load Balancers

**Clusters:** `gke-std-dpv1` (us-central1) and `gke-std-dpv2` (us-west1)
**Manifests:** `dpv1/backend-svc-ilb.yaml` and `dpv2/backend-svc-ilb.yaml`
**Load Balancer Type:** GCP Internal Passthrough Network Load Balancer (NLB)

---

## What the manifests provision

Both files are nearly identical — the only difference is the `cluster` label:

```yaml
# dpv1
labels:
  app: backend
  cluster: gke-std-dpv1

# dpv2
labels:
  app: backend
  cluster: gke-std-dpv2
```

Everything else — annotations, spec, ports — is the same. One manifest per
cluster, each provisioning one **GCP Internal Passthrough Network Load Balancer**.

---

## What `type: LoadBalancer` actually does in GKE

When GKE sees `type: LoadBalancer`, it calls out to the **GCP
cloud-controller-manager** running in the cluster. That controller:

1. Allocates an IP from the **node subnet** (not the pod or service CIDR)
2. Creates a GCP **forwarding rule** pointing to a **backend service**
3. Creates a **health check** targeting the node's `NodePort` for this service
4. Registers all cluster nodes as backends in a **backend service**
5. Writes the allocated IP back to `Service.status.loadBalancer.ingress[0].ip`

Without the `cloud.google.com/load-balancer-type: "Internal"` annotation, this
would provision an **external** passthrough NLB with a public IP. That annotation
is what makes it internal.

---

## The two critical annotations

### `cloud.google.com/load-balancer-type: "Internal"`

Instructs the cloud-controller-manager to create a **GCP Internal Passthrough
Network Load Balancer** instead of an external one. The resulting forwarding rule
is bound to the VPC — the IP is only reachable from within `vpc-global` or
connected networks (VPN, Interconnect).

IP allocation comes from the **node subnet**:

| Cluster | Node Subnet | Node Subnet CIDR | ILB IP |
|---|---|---|---|
| `gke-std-dpv1` | `central-vpc-subnet-01` | `10.0.0.0/20` | `10.0.0.11` |
| `gke-std-dpv2` | `west-vpc-subnet-01` | `10.1.0.0/20` | `10.1.0.6` |

These IPs are what the `svc.internal` Cloud DNS A records point to:

```
backend-central.svc.internal → 10.0.0.11  (dpv1 ILB)
backend-west.svc.internal    → 10.1.0.6   (dpv2 ILB)
```

### `networking.gke.io/internal-load-balancer-allow-global-access: "true"`

This annotation unblocked Test 4 (cross-cluster HTTP). Without it, the ILB
operates in **regional mode** — GCP's load balancer subsystem only accepts
traffic sourced from the **same region** as the forwarding rule. Traffic from
`us-central1` pods hitting the `us-west1` ILB at `10.1.0.6` was silently
dropped at the GCP load balancer layer, before the packet even reached a
firewall rule.

With this annotation set, the ILB forwarding rule is upgraded to **global access
mode** — traffic from any region within the VPC is accepted. This is what made
the cross-region path work:

```
dpv1 pod (us-central1) → 10.1.0.6  (us-west1 ILB, global access) → dpv2 backend pod (us-west1)
dpv2 pod (us-west1)    → 10.0.0.11 (us-central1 ILB, global access) → dpv1 backend pod (us-central1)
```

---

## Traffic flow end-to-end

Taking the cross-region case from Test 4 — dpv2 pod calling dpv1's ILB:

```
1.  Pod on gke-std-dpv2 calls: curl http://backend-central.svc.internal
2.  DNS query → 169.254.20.10 (node-local Cloud DNS stub)
3.  Stub forwards → 169.254.169.254 (Cloud DNS VPC resolver)
4.  Cloud DNS returns A record: backend-central.svc.internal → 10.0.0.11
5.  Pod opens TCP connection to 10.0.0.11:80
6.  VPC routing (GLOBAL mode) forwards packet from us-west1 → us-central1
7.  GCP forwarding rule on ILB receives packet at 10.0.0.11:80
8.  ILB selects a healthy backend node from gke-std-dpv1 node pool
9.  Packet arrives at the node's NodePort for the backend-ilb Service
10. kube-proxy (dpv1) or eBPF (dpv2) NATs the packet to a backend pod IP
11. whereami pod responds — response flows back through the same path
```

The ILB is **passthrough** — it does not terminate TCP or modify the packet.
The backend pod sees the original source IP of the calling pod.

---

## Port mapping

```yaml
ports:
- name: http
  port: 80          # the ILB listener port — what callers connect to
  targetPort: 8080  # the port whereami listens on inside the container
  protocol: TCP
```

GKE automatically allocates a **NodePort** (e.g. `30xxx`) and programs the ILB
health check to probe that NodePort. The ILB itself listens on port 80, and
the forwarding happens:

```
ILB:80 → NodePort:30xxx → Pod:8080
```

---

## What is NOT in these manifests (by design)

| Missing field | Why |
|---|---|
| `loadBalancerIP` | Not specified — GCP allocates from the subnet automatically. To use a stable pre-reserved IP, create one with `gcloud compute addresses create` and reference it here. |
| `externalTrafficPolicy` | Defaults to `Cluster` — kube-proxy/eBPF may forward to a pod on a different node, adding a hop. `Local` skips the extra hop but changes health check behavior. |
| `sessionAffinity` | None — requests are distributed round-robin across all healthy backend pods. |
| Subnet annotation | Not needed — one node subnet per cluster. Multi-subnet clusters would need `networking.gke.io/subnetwork` to control which subnet the ILB IP is allocated from. |

---

## Manual Validation Commands

**Confirm the ILB has an assigned IP (not pending):**

```bash
# Get just the assigned IP
kubectl get svc backend-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'

# Full service detail including NodePort
kubectl get svc backend-ilb -o wide
```

**Confirm global access is enabled:**

```bash
kubectl get svc backend-ilb -o jsonpath='{.metadata.annotations}{"\n"}'
```

**Confirm the ILB IP is within the node subnet CIDR:**

```bash
# dpv1 — should return an IP in 10.0.0.0/20
gcloud container clusters describe gke-std-dpv1 \
  --region=us-central1 \
  --project=gillman-gke-dns \
  --format='value(nodeConfig.machineType)' # cross-reference subnet from VPC config

# List the forwarding rule GKE created in GCP (named after the service)
gcloud compute forwarding-rules list \
  --project=gillman-gke-dns \
  --filter='loadBalancingScheme=INTERNAL' \
  --format='table(name,IPAddress,region,loadBalancingScheme,backendService)'
```

**Confirm the Cloud DNS A records point to the correct ILB IPs:**

```bash
gcloud dns record-sets list \
  --zone=svc-internal \
  --project=gillman-gke-dns \
  --format='table(name,type,ttl,rrdatas)'
```

**Test cross-cluster HTTP — confirms ILB + global access + DNS all working:**

```bash
# From dpv1 debug pod — should respond with cluster_name: gke-std-dpv1 (loopback)
kubectl exec -it debug -- curl -s http://backend-central.svc.internal

# From dpv1 debug pod — should respond with cluster_name: gke-std-dpv2 (cross-region)
kubectl exec -it debug -- curl -s http://backend-west.svc.internal
```

**Confirm the GCP backend service and health check status:**

```bash
# List backend services created by GKE for internal LBs
gcloud compute backend-services list \
  --project=gillman-gke-dns \
  --filter='loadBalancingScheme=INTERNAL' \
  --format='table(name,region,protocol,loadBalancingScheme)'
```
