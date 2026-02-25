# ─────────────────────────────────────────────────────────────────────────────
# Post-apply validation using Terraform check blocks (requires >= 1.5.0)
#
# Each check block reads live state back from the Google Cloud API and asserts
# that it matches the intended configuration. Failures surface as warnings in
# the apply output without rolling back the deployment.
# ─────────────────────────────────────────────────────────────────────────────

# ── VPC ───────────────────────────────────────────────────────────────────────

check "vpc_global" {
  # auto_create_subnetworks and routing_mode are not exported by the
  # google_compute_network data source, so we validate using attributes
  # that are available: self_link (existence) and subnetworks_self_links (count).
  data "google_compute_network" "vpc_check" {
    name    = google_compute_network.vpc_global.name
    project = var.project_id
  }

  assert {
    condition     = data.google_compute_network.vpc_check.self_link != ""
    error_message = "VPC 'vpc-global' was not found or returned an empty self_link."
  }

  assert {
    condition     = length(data.google_compute_network.vpc_check.subnetworks_self_links) == 3
    error_message = "VPC 'vpc-global' should have exactly 3 subnets attached."
  }
}

# ── Central subnet ────────────────────────────────────────────────────────────

check "central_subnet" {
  data "google_compute_subnetwork" "central_check" {
    name    = google_compute_subnetwork.central.name
    region  = var.central_region
    project = var.project_id
  }

  assert {
    condition     = data.google_compute_subnetwork.central_check.ip_cidr_range == var.central_subnet_cidr
    error_message = "central-vpc-subnet-01 primary CIDR is '${data.google_compute_subnetwork.central_check.ip_cidr_range}', expected '${var.central_subnet_cidr}'."
  }

  assert {
    condition     = data.google_compute_subnetwork.central_check.private_ip_google_access == true
    error_message = "central-vpc-subnet-01 must have private_ip_google_access enabled."
  }

  assert {
    condition = anytrue([
      for r in data.google_compute_subnetwork.central_check.secondary_ip_range :
      r.range_name == "central-pods" && r.ip_cidr_range == var.central_pods_cidr
    ])
    error_message = "central-vpc-subnet-01 is missing secondary range 'central-pods' (${var.central_pods_cidr})."
  }

  assert {
    condition = anytrue([
      for r in data.google_compute_subnetwork.central_check.secondary_ip_range :
      r.range_name == "central-services" && r.ip_cidr_range == var.central_services_cidr
    ])
    error_message = "central-vpc-subnet-01 is missing secondary range 'central-services' (${var.central_services_cidr})."
  }
}

# ── West subnet ───────────────────────────────────────────────────────────────

check "west_subnet" {
  data "google_compute_subnetwork" "west_check" {
    name    = google_compute_subnetwork.west.name
    region  = var.west_region
    project = var.project_id
  }

  assert {
    condition     = data.google_compute_subnetwork.west_check.ip_cidr_range == var.west_subnet_cidr
    error_message = "west-vpc-subnet-01 primary CIDR is '${data.google_compute_subnetwork.west_check.ip_cidr_range}', expected '${var.west_subnet_cidr}'."
  }

  assert {
    condition     = data.google_compute_subnetwork.west_check.private_ip_google_access == true
    error_message = "west-vpc-subnet-01 must have private_ip_google_access enabled."
  }

  assert {
    condition = anytrue([
      for r in data.google_compute_subnetwork.west_check.secondary_ip_range :
      r.range_name == "west-pods" && r.ip_cidr_range == var.west_pods_cidr
    ])
    error_message = "west-vpc-subnet-01 is missing secondary range 'west-pods' (${var.west_pods_cidr})."
  }

  assert {
    condition = anytrue([
      for r in data.google_compute_subnetwork.west_check.secondary_ip_range :
      r.range_name == "west-services" && r.ip_cidr_range == var.west_services_cidr
    ])
    error_message = "west-vpc-subnet-01 is missing secondary range 'west-services' (${var.west_services_cidr})."
  }
}

# ── East subnet ───────────────────────────────────────────────────────────────

check "east_subnet" {
  data "google_compute_subnetwork" "east_check" {
    name    = google_compute_subnetwork.east.name
    region  = var.east_region
    project = var.project_id
  }

  assert {
    condition     = data.google_compute_subnetwork.east_check.ip_cidr_range == var.east_subnet_cidr
    error_message = "east-vpc-subnet-01 primary CIDR is '${data.google_compute_subnetwork.east_check.ip_cidr_range}', expected '${var.east_subnet_cidr}'."
  }

  assert {
    condition     = data.google_compute_subnetwork.east_check.private_ip_google_access == true
    error_message = "east-vpc-subnet-01 must have private_ip_google_access enabled."
  }

  assert {
    condition = anytrue([
      for r in data.google_compute_subnetwork.east_check.secondary_ip_range :
      r.range_name == "east-pods" && r.ip_cidr_range == var.east_pods_cidr
    ])
    error_message = "east-vpc-subnet-01 is missing secondary range 'east-pods' (${var.east_pods_cidr})."
  }

  assert {
    condition = anytrue([
      for r in data.google_compute_subnetwork.east_check.secondary_ip_range :
      r.range_name == "east-services" && r.ip_cidr_range == var.east_services_cidr
    ])
    error_message = "east-vpc-subnet-01 is missing secondary range 'east-services' (${var.east_services_cidr})."
  }
}

# ── Cloud Routers ─────────────────────────────────────────────────────────────

check "router_central" {
  data "google_compute_router" "central_check" {
    name    = google_compute_router.central.name
    network = google_compute_network.vpc_global.name
    region  = var.central_region
    project = var.project_id
  }

  assert {
    condition     = data.google_compute_router.central_check.network != ""
    error_message = "Cloud Router 'router-central' does not appear to be attached to a network."
  }
}

check "router_west" {
  data "google_compute_router" "west_check" {
    name    = google_compute_router.west.name
    network = google_compute_network.vpc_global.name
    region  = var.west_region
    project = var.project_id
  }

  assert {
    condition     = data.google_compute_router.west_check.network != ""
    error_message = "Cloud Router 'router-west' does not appear to be attached to a network."
  }
}

check "router_east" {
  data "google_compute_router" "east_check" {
    name    = google_compute_router.east.name
    network = google_compute_network.vpc_global.name
    region  = var.east_region
    project = var.project_id
  }

  assert {
    condition     = data.google_compute_router.east_check.network != ""
    error_message = "Cloud Router 'router-east' does not appear to be attached to a network."
  }
}
