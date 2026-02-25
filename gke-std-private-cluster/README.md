# GKE Standard Private Cluster Deployment Scripts

This directory contains the scripts to create the two GKE Standard private clusters used in
this project. Each script is purpose-built for its cluster's dataplane and DNS configuration.

| Script | Cluster | Dataplane | DNS |
|---|---|---|---|
| `create-gke-dpv1-cluster.sh` | `gke-std-dpv1` | V1 — `LEGACY_DATAPATH` (kube-proxy) | kube-dns (`cluster.local`) |
| `create-gke-dpv2-cluster.sh` | `gke-std-dpv2` | V2 — `ADVANCED_DATAPATH` (eBPF) | Cloud DNS (VPC scope) |

> **Prerequisite:** The VPC networking in `vpc-networking/` must be fully deployed before
> running either script. Both scripts reference pre-existing subnets and named secondary IP
> ranges that Terraform creates.

---

## Features

Both scripts provision a GKE Standard cluster with the following features enabled by default:

- **Private nodes** — worker node VMs have no external IP addresses
- **Fully private control plane** — no public IP, no IP-based endpoint (`--no-enable-ip-access`)
- **DNS-based endpoint** — the sole method for `kubectl` access (`--enable-dns-access`)
- **Workload Identity** — secure authentication of workloads to Google Cloud services
- **Shielded nodes** — verifiable node integrity with integrity monitoring enabled
- **Custom VPC networking** — deploys into pre-existing VPC subnets with named secondary ranges
- **Enhanced monitoring** — system, storage, pod, deployment, HPA, kubelet, cAdvisor, DCGM
- **Managed Prometheus** — Prometheus-compatible metrics scraping
- **Gateway API** — standard channel enabled

`create-gke-dpv2-cluster.sh` additionally enables:

- **Dataplane V2** (`--enable-dataplane-v2`) — eBPF-based CNI replacing kube-proxy
- **DPv2 metrics** (`--enable-dataplane-v2-metrics`)
- **DPv2 flow observability** (`--enable-dataplane-v2-flow-observability`)
- **Cloud DNS** (`--cluster-dns=clouddns --cluster-dns-scope=vpc`) — replaces kube-dns with a
  node-local stub resolver; VPC scope makes all private Cloud DNS zones automatically resolvable

---

## Configuration

All cluster parameters are defined in `config.sh`, sourced automatically by both scripts.
The file is gitignored — it is never committed.

### Step 1 — Create your configuration file

```bash
cp config.sh.example config.sh
```

### Step 2 — Edit `config.sh`

Key variables to set before running either script:

| Variable | dpv1 value | dpv2 value |
|---|---|---|
| `PROJECT_ID` | your project ID | your project ID |
| `CLUSTER_NAME` | `gke-std-dpv1` | `gke-std-dpv2` |
| `REGION` | `us-central1` | `us-west1` |
| `ZONE` | `us-central1-a` | `us-west1-a` |
| `VPC_NETWORK_NAME` | `vpc-global` | `vpc-global` |
| `VPC_SUBNET_NAME` | `central-vpc-subnet-01` | `west-vpc-subnet-01` |
| `POD_RANGE_NAME` | `central-pods` | `west-pods` |
| `SERVICES_RANGE_NAME` | `central-services` | `west-services` |
| `POD_CIDR` | `10.4.0.0/14` | `10.8.0.0/14` |
| `SERVICE_CIDR` | `10.16.0.0/20` | `10.17.0.0/20` |
| `CLUSTER_DNS_DOMAIN` | *(not used)* | `gke-std-dpv2.local` |

`CLUSTER_DNS_DOMAIN` is only referenced by `create-gke-dpv2-cluster.sh`. It sets the custom
cluster DNS domain required when using Cloud DNS with VPC scope — each cluster sharing the
same VPC must have a unique domain to avoid DNS conflicts.

---

## Usage

### Create gke-std-dpv1 (Dataplane V1, kube-dns)

```bash
chmod +x create-gke-dpv1-cluster.sh
./create-gke-dpv1-cluster.sh
```

### Create gke-std-dpv2 (Dataplane V2, Cloud DNS)

```bash
chmod +x create-gke-dpv2-cluster.sh
./create-gke-dpv2-cluster.sh
```

Both scripts will:
1. Check prerequisites (`gcloud` installed, authenticated, `PROJECT_ID` set)
2. Enable required Google Cloud APIs
3. Display the full configuration and prompt for confirmation before creating anything
4. Create the cluster (~10–15 minutes)
5. Configure `kubectl` credentials via the DNS-based endpoint
6. Verify the cluster configuration (dataplane, DNS provider, Workload Identity, private nodes,
   Managed Prometheus)
7. Print access and monitoring instructions

---

## Post-Creation

### Accessing the cluster

Both clusters use the GKE DNS-based endpoint exclusively. The control plane has no public IP.
Access requires running from within Google Cloud (GCE VM, Cloud Shell, GKE pod) or via Cloud
VPN / Cloud Interconnect into the VPC.

```bash
# Fetch credentials (DNS endpoint)
gcloud container clusters get-credentials CLUSTER_NAME \
  --region=REGION \
  --project=PROJECT_ID \
  --dns-endpoint

# Verify connectivity
kubectl get nodes
kubectl cluster-info
```

### Verifying cluster configuration

```bash
# Confirm dataplane provider
gcloud container clusters describe CLUSTER_NAME \
  --region=REGION --project=PROJECT_ID \
  --format='value(networkConfig.datapathProvider)'
# dpv1 expected: LEGACY_DATAPATH
# dpv2 expected: ADVANCED_DATAPATH

# Confirm no public IP endpoint
gcloud container clusters describe CLUSTER_NAME \
  --region=REGION --project=PROJECT_ID \
  --format='value(controlPlaneEndpointsConfig.ipEndpointsConfig.enabled)'
# Expected: False

# Confirm DNS-based endpoint is active
gcloud container clusters describe CLUSTER_NAME \
  --region=REGION --project=PROJECT_ID \
  --format='value(controlPlaneEndpointsConfig.dnsEndpointConfig.enabled)'
# Expected: True

# dpv2 only — confirm Cloud DNS configuration
gcloud container clusters describe gke-std-dpv2 \
  --region=us-west1 --project=PROJECT_ID \
  --format='table(
    networkConfig.dnsConfig.clusterDns,
    networkConfig.dnsConfig.clusterDnsScope,
    networkConfig.dnsConfig.clusterDnsDomain
  )'
# Expected: CLOUD_DNS | VPC_SCOPE | gke-std-dpv2.local
```
