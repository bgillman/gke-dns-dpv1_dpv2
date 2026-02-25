# vpc-networking

Terraform configuration that provisions a production-ready Google Cloud VPC network from scratch on a brand-new project. A single `terraform apply` enables required APIs, removes the default VPC, and builds the complete network topology in one ordered pass.

---

## What this builds

```
Google Cloud Project
└── vpc-global  (custom-mode VPC, global routing)
    ├── central-vpc-subnet-01  (us-central1)  10.0.0.0/20
    │   ├── secondary: central-pods            10.4.0.0/14
    │   └── secondary: central-services        10.16.0.0/20
    ├── west-vpc-subnet-01     (us-west1)     10.1.0.0/20
    │   ├── secondary: west-pods               10.8.0.0/14
    │   └── secondary: west-services           10.17.0.0/20
    └── east-vpc-subnet-01     (us-east1)     10.2.0.0/20
        ├── secondary: east-pods               10.12.0.0/14
        └── secondary: east-services           10.18.0.0/20

Per-region supporting resources (all three regions):
  Cloud Router  →  router-{central,west,east}
  Cloud NAT     →  nat-{central,west,east}
```

---

## Prerequisites

| Tool | Minimum version |
|---|---|
| Terraform | 1.5.0 |
| Google provider (`hashicorp/google`) | ~> 5.0 |
| `gcloud` CLI | Any recent version (used by cleanup step and `validate.sh`) |

The identity running `terraform apply` must have at minimum:
- `roles/serviceusage.serviceUsageAdmin` — to enable APIs
- `roles/compute.networkAdmin` — to create/delete VPC resources
- `roles/compute.securityAdmin` — to delete default firewall rules

---

## File structure

```
vpc-networking/
├── provider.tf              # Google provider + Terraform version constraints
├── apis.tf                  # Enables required Google Cloud APIs
├── default-vpc-cleanup.tf   # Removes the GCP-generated default VPC
├── main.tf                  # VPC, subnets, Cloud Routers, Cloud NAT
├── variables.tf             # All input variables with defaults
├── outputs.tf               # Self-links, IDs, and GKE secondary range names
├── validation.tf            # Terraform check blocks (post-apply assertions)
├── terraform.tfvars         # Local overrides — gitignored, never committed
├── terraform.tfvars.example # Safe committed template (no real values)
└── validate.sh              # Standalone gcloud-based verification script
```

---

## Quick start

### 1. Set the project ID via environment variable

`project_id` is the only required variable. It is supplied via a `TF_VAR_*`
environment variable so it never appears in any committed file:

```bash
export TF_VAR_project_id="your-google-cloud-project-id"
```

Terraform automatically maps any `TF_VAR_<name>` environment variable to the
corresponding input variable (`var.project_id` in this case). No value needs
to be set in `terraform.tfvars`.

To make this persistent across shell sessions, add it to your shell profile
(`~/.bashrc`, `~/.zshrc`, etc.) or use a secrets manager / `.env` loader that
is itself gitignored.

### 2. (Optional) Local overrides

If you need to override any default values (regions, CIDRs, VPC name), copy
the example file and edit it locally:

```bash
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars is gitignored — safe to add real values here
```

### 3. Deploy

```bash
# Download the Google provider
terraform init

# Preview what will be created
terraform plan

# Deploy
terraform apply

# Verify
./validate.sh
```

---

## How it works: execution order

Terraform resolves `depends_on` relationships and builds a directed acyclic graph (DAG) before executing. The resources in this configuration are intentionally ordered so that each phase completes before the next begins.

### Phase 1 — Enable APIs (`apis.tf`)

```hcl
resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)
  ...
}
```

Nine Google Cloud APIs are enabled in parallel using a `for_each` over a local list. This is the entry point for everything else — no compute resource can be created until its API is active.

| API | Purpose |
|---|---|
| `compute.googleapis.com` | VPC, subnets, Cloud Router, Cloud NAT |
| `container.googleapis.com` | GKE (future clusters) |
| `cloudresourcemanager.googleapis.com` | Provider initialization, IAM lookups |
| `iam.googleapis.com` | Service accounts and IAM bindings |
| `logging.googleapis.com` | VPC Flow Logs, Cloud NAT logs |
| `monitoring.googleapis.com` | GKE system metrics |
| `dns.googleapis.com` | Internal DNS used by GKE |
| `servicenetworking.googleapis.com` | Private Service Connect / PSA |
| `networkmanagement.googleapis.com` | Network Intelligence Center |

`disable_on_destroy = false` is set on all services so that a `terraform destroy` does not disable APIs that other tools or services in the project may rely on.

---

### Phase 2 — Delete the default VPC (`default-vpc-cleanup.tf`)

```hcl
resource "terraform_data" "delete_default_vpc" {
  triggers_replace = [var.project_id]
  provisioner "local-exec" { ... }
  depends_on = [google_project_service.apis]
}
```

Every new Google Cloud project is created with a `default` VPC network and four permissive firewall rules (`default-allow-icmp`, `default-allow-internal`, `default-allow-rdp`, `default-allow-ssh`). This resource removes them before any custom infrastructure is built.

**Why remove it?** Leaving the default VPC in place creates an implicit network that workloads might accidentally attach to, and the default firewall rules allow broad lateral movement within the network. Removing it enforces that only explicitly-defined networks exist in the project.

The cleanup runs a `local-exec` shell script that:
1. Checks whether the default network exists — if not, exits cleanly (idempotent)
2. Iterates over and deletes all firewall rules attached to the default network
3. Deletes the default network itself

`triggers_replace = [var.project_id]` causes Terraform to record a fingerprint in state after the first run. On every subsequent `terraform apply`, if the project ID has not changed, this resource is a no-op — the provisioner does not re-run.

---

### Phase 3 — Create `vpc-global` (`main.tf`)

```hcl
resource "google_compute_network" "vpc_global" {
  name                    = var.vpc_name          # "vpc-global"
  auto_create_subnetworks = false                 # custom mode
  routing_mode            = "GLOBAL"
  depends_on = [
    google_project_service.apis,
    terraform_data.delete_default_vpc,
  ]
}
```

The VPC will not be created until both Phase 1 and Phase 2 have completed. Key settings:

- **`auto_create_subnetworks = false`** — custom mode. GCP will not automatically generate a subnet in every region. Only the subnets defined in this Terraform configuration will exist.
- **`routing_mode = "GLOBAL"`** — Cloud Routers in any region can exchange routes with Cloud Routers in any other region over the same VPC. This is required for multi-region topologies.
- **`delete_default_routes_on_create = false`** — preserves the default `0.0.0.0/0` internet gateway route so that Cloud NAT can use it for egress.

---

### Phase 4 — Create subnets (`main.tf`)

Three subnets are created in parallel, each referencing `google_compute_network.vpc_global.id`. Terraform's implicit dependency on the VPC ID means subnets cannot be created until Phase 3 is complete.

Each subnet is configured identically in terms of features:

#### Primary CIDR (`/20` — 4,096 addresses per subnet)

| Subnet | Region | CIDR |
|---|---|---|
| `central-vpc-subnet-01` | `us-central1` | `10.0.0.0/20` |
| `west-vpc-subnet-01` | `us-west1` | `10.1.0.0/20` |
| `east-vpc-subnet-01` | `us-east1` | `10.2.0.0/20` |

These addresses are used by VM instances and GKE nodes (the VMs themselves, not the pods they run).

#### `private_ip_google_access = true`

Allows resources in the subnet to reach Google APIs and services (Cloud Storage, Artifact Registry, etc.) over the private Google network, without requiring a public IP address or an internet gateway route. This is essential for private GKE nodes.

#### VPC Flow Logs

```hcl
log_config {
  aggregation_interval = "INTERVAL_5_SEC"
  flow_sampling        = 0.5
  metadata             = "INCLUDE_ALL_METADATA"
}
```

Captures a sample (50%) of network flow records every 5 seconds with full metadata. Logs are written to Cloud Logging and can be exported to BigQuery for analysis. Useful for traffic visibility, security auditing, and debugging connectivity issues.

#### Secondary IP ranges (alias IP ranges for GKE)

Each subnet carries two secondary ranges. These are not used by the subnet's primary workloads — they are reserved for GKE and referenced by name when creating a cluster.

**Pod ranges (`/14` — 262,144 addresses)**

GKE assigns a `/24` block from this range to each node. With a `/14` range and 256 nodes-worth of `/24` blocks available, this supports large clusters.

| Range name | Subnet | CIDR |
|---|---|---|
| `central-pods` | `central-vpc-subnet-01` | `10.4.0.0/14` |
| `west-pods` | `west-vpc-subnet-01` | `10.8.0.0/14` |
| `east-pods` | `east-vpc-subnet-01` | `10.12.0.0/14` |

**Services ranges (`/20` — 4,096 addresses)**

GKE assigns one IP from this range to each Kubernetes Service (ClusterIP). A `/20` supports up to 4,096 services per cluster.

| Range name | Subnet | CIDR |
|---|---|---|
| `central-services` | `central-vpc-subnet-01` | `10.16.0.0/20` |
| `west-services` | `west-vpc-subnet-01` | `10.17.0.0/20` |
| `east-services` | `east-vpc-subnet-01` | `10.18.0.0/20` |

**No IP ranges overlap.** The full address plan:

```
10.0.0.0/20   — central nodes
10.1.0.0/20   — west nodes
10.2.0.0/20   — east nodes
10.4.0.0/14   — central pods   (10.4.0.0 – 10.7.255.255)
10.8.0.0/14   — west pods      (10.8.0.0 – 10.11.255.255)
10.12.0.0/14  — east pods      (10.12.0.0 – 10.15.255.255)
10.16.0.0/20  — central services
10.17.0.0/20  — west services
10.18.0.0/20  — east services
```

---

### Phase 5 — Cloud Routers and Cloud NAT (`main.tf`)

One Cloud Router and one Cloud NAT gateway are created per region. These are implicit dependents of the VPC and are created in parallel across the three regions once Phase 3 completes.

**Cloud Router** (`router-{central,west,east}`)

A Cloud Router is a regional resource that enables dynamic routing within a VPC. It is a prerequisite for Cloud NAT — NAT gateways attach to a router.

**Cloud NAT** (`nat-{central,west,east}`)

```hcl
nat_ip_allocate_option             = "AUTO_ONLY"
source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
```

Provides outbound internet access for resources that have no public IP address — primarily GKE nodes and pods pulling container images or reaching external APIs. `AUTO_ONLY` means GCP allocates and manages the external NAT IPs automatically. `ALL_SUBNETWORKS_ALL_IP_RANGES` covers both the primary node range and the secondary pod range.

NAT error logging is enabled (`filter = "ERRORS_ONLY"`) to surface port exhaustion and translation failures in Cloud Logging.

---

## Variables

All variables have defaults and can be overridden in `terraform.tfvars`.

| Variable | Default | Description |
|---|---|---|
| `project_id` | *(required)* | Google Cloud project ID |
| `default_region` | `us-central1` | Provider default region |
| `vpc_name` | `vpc-global` | Name of the VPC network |
| `central_region` | `us-central1` | Region for central subnet |
| `west_region` | `us-west1` | Region for west subnet |
| `east_region` | `us-east1` | Region for east subnet |
| `central_subnet_cidr` | `10.0.0.0/20` | Central node CIDR |
| `west_subnet_cidr` | `10.1.0.0/20` | West node CIDR |
| `east_subnet_cidr` | `10.2.0.0/20` | East node CIDR |
| `central_pods_cidr` | `10.4.0.0/14` | Central GKE pod range |
| `west_pods_cidr` | `10.8.0.0/14` | West GKE pod range |
| `east_pods_cidr` | `10.12.0.0/14` | East GKE pod range |
| `central_services_cidr` | `10.16.0.0/20` | Central GKE service range |
| `west_services_cidr` | `10.17.0.0/20` | West GKE service range |
| `east_services_cidr` | `10.18.0.0/20` | East GKE service range |

---

## Outputs

After a successful apply, `terraform output` returns the following values. These are the exact values you will pass to downstream Terraform modules (e.g., a GKE cluster module).

| Output | Description |
|---|---|
| `vpc_name` | Name of the VPC network |
| `vpc_self_link` | Full self-link URI of the VPC |
| `vpc_id` | Unique resource ID of the VPC |
| `central_subnet_self_link` | Self-link of `central-vpc-subnet-01` |
| `central_subnet_id` | ID of `central-vpc-subnet-01` |
| `west_subnet_self_link` | Self-link of `west-vpc-subnet-01` |
| `west_subnet_id` | ID of `west-vpc-subnet-01` |
| `east_subnet_self_link` | Self-link of `east-vpc-subnet-01` |
| `east_subnet_id` | ID of `east-vpc-subnet-01` |
| `central_pods_range_name` | `"central-pods"` — used in GKE cluster config |
| `central_services_range_name` | `"central-services"` — used in GKE cluster config |
| `west_pods_range_name` | `"west-pods"` |
| `west_services_range_name` | `"west-services"` |
| `east_pods_range_name` | `"east-pods"` |
| `east_services_range_name` | `"east-services"` |

---

## Validation

This configuration includes two independent validation layers that complement each other.

### Layer 1 — Terraform `check` blocks (`validation.tf`)

Terraform 1.5 introduced `check` blocks as a native post-apply assertion mechanism. After all resources are created, each `check` block uses a scoped data source to read the live state of a resource directly from the Google Cloud API and asserts that it matches the expected configuration.

Failures are reported as **warnings** in the apply output — they do not roll back the deployment, but they make any misconfiguration immediately visible.

**VPC checks** (`check "vpc_global"`)
- Asserts `self_link` is non-empty, confirming the network was successfully created
- Asserts exactly 3 subnets are attached to the VPC

**Subnet checks** (`check "central_subnet"`, `check "west_subnet"`, `check "east_subnet"`)

Each subnet block runs four assertions:
1. The primary CIDR matches the configured value
2. `private_ip_google_access` is enabled
3. The pods secondary range exists with the correct name and CIDR
4. The services secondary range exists with the correct name and CIDR

The pods and services checks use Terraform's `anytrue()` with a `for` expression to search the list of secondary ranges for a matching entry — both the range name and the CIDR must match exactly.

**Cloud Router checks** (`check "router_central"`, etc.)
- Asserts each router's `network` attribute is non-empty, confirming it is attached to the VPC

---

### Layer 2 — `validate.sh`

A standalone Bash script that queries the Google Cloud API directly via `gcloud`. It can be run at any time, independent of Terraform state, making it suitable for:
- Post-deployment smoke tests in a CI/CD pipeline
- Periodic scheduled verification
- Manual spot checks by operators

**Usage**

```bash
# Reads project_id automatically from terraform.tfvars
./validate.sh

# Or pass the project ID explicitly
./validate.sh your-project-id
```

The script exits with code `0` on full success and code `1` if any check fails, making it compatible with CI systems that check exit codes.

**What it checks**

The script is organized into five sections, each printed with a colored header:

**1. Required APIs**

Fetches the list of enabled services and checks each of the 9 required APIs. A missing API will show as `[FAIL]` and increment the failure counter.

**2. VPC Network**

Describes `vpc-global` and parses the JSON response to verify:
- The network exists
- `autoCreateSubnetworks` is `false`
- `routingMode` is `GLOBAL`

Note: the `validate.sh` script can check `autoCreateSubnetworks` and `routingMode` because it parses the raw gcloud JSON response, which includes these fields. The Terraform `check` blocks cannot check these because the Terraform Google provider's `google_compute_network` data source does not export them as readable attributes.

**3. Subnets**

A reusable `check_subnet()` function is called once per subnet with its expected values as arguments. For each subnet it verifies:
- The subnet exists in the correct region
- `ipCidrRange` matches the expected `/20` CIDR
- `privateIpGoogleAccess` is `true`
- Both secondary ranges exist with the correct names and CIDRs

**4. Cloud Routers**

Confirms each Cloud Router (`router-central`, `router-west`, `router-east`) exists in its respective region.

**5. Cloud NAT**

Confirms each Cloud NAT gateway (`nat-central`, `nat-west`, `nat-east`) exists, attached to its respective Cloud Router.

**Example output**

```
VPC Networking Infrastructure Validation
[INFO] Project: your-project-id

── Required APIs
  [PASS] compute.googleapis.com
  [PASS] container.googleapis.com
  [PASS] iam.googleapis.com
  ...

── VPC Network: vpc-global
  [PASS] vpc-global exists
  [PASS] autoCreateSubnetworks = false (custom mode)
  [PASS] routingMode = GLOBAL

── Subnet: central-vpc-subnet-01 (us-central1)
  [PASS] central-vpc-subnet-01 exists
  [PASS] primaryCidr = 10.0.0.0/20
  [PASS] privateIpGoogleAccess = true
  [PASS] secondary range 'central-pods' = 10.4.0.0/14
  [PASS] secondary range 'central-services' = 10.16.0.0/20
...

────────────────────────────────────────
All checks passed.
```

---

## Using outputs with a GKE cluster

When creating a GKE cluster in a downstream Terraform module or configuration, reference this module's outputs to wire up the network correctly:

```hcl
resource "google_container_cluster" "example" {
  name    = "my-cluster"
  network = data.terraform_remote_state.vpc.outputs.vpc_self_link

  node_config {
    # nodes are placed in the subnet's primary range
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = data.terraform_remote_state.vpc.outputs.central_pods_range_name
    services_secondary_range_name = data.terraform_remote_state.vpc.outputs.central_services_range_name
  }

  private_cluster_config {
    enable_private_nodes = true
    # Cloud NAT in this config provides outbound internet access for private nodes
  }
}
```
