# ─────────────────────────────────────────────────────────────────────────────
# VPC Network
# ─────────────────────────────────────────────────────────────────────────────

resource "google_compute_network" "vpc_global" {
  name                            = var.vpc_name
  auto_create_subnetworks         = false
  routing_mode                    = "GLOBAL"
  delete_default_routes_on_create = false

  description = "Global shared VPC with regional subnets for central, west, and east workloads."

  depends_on = [
    google_project_service.apis,
    terraform_data.delete_default_vpc,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Subnets
# ─────────────────────────────────────────────────────────────────────────────

resource "google_compute_subnetwork" "central" {
  name          = "central-vpc-subnet-01"
  network       = google_compute_network.vpc_global.id
  region        = var.central_region
  ip_cidr_range = var.central_subnet_cidr

  # Enables VPC Flow Logs for visibility into traffic patterns
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "central-pods"
    ip_cidr_range = var.central_pods_cidr
  }

  secondary_ip_range {
    range_name    = "central-services"
    ip_cidr_range = var.central_services_cidr
  }
}

resource "google_compute_subnetwork" "west" {
  name          = "west-vpc-subnet-01"
  network       = google_compute_network.vpc_global.id
  region        = var.west_region
  ip_cidr_range = var.west_subnet_cidr

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "west-pods"
    ip_cidr_range = var.west_pods_cidr
  }

  secondary_ip_range {
    range_name    = "west-services"
    ip_cidr_range = var.west_services_cidr
  }
}

resource "google_compute_subnetwork" "east" {
  name          = "east-vpc-subnet-01"
  network       = google_compute_network.vpc_global.id
  region        = var.east_region
  ip_cidr_range = var.east_subnet_cidr

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "east-pods"
    ip_cidr_range = var.east_pods_cidr
  }

  secondary_ip_range {
    range_name    = "east-services"
    ip_cidr_range = var.east_services_cidr
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Cloud Router (one per region — required for Cloud NAT)
# ─────────────────────────────────────────────────────────────────────────────

resource "google_compute_router" "central" {
  name    = "router-central"
  network = google_compute_network.vpc_global.id
  region  = var.central_region
}

resource "google_compute_router" "west" {
  name    = "router-west"
  network = google_compute_network.vpc_global.id
  region  = var.west_region
}

resource "google_compute_router" "east" {
  name    = "router-east"
  network = google_compute_network.vpc_global.id
  region  = var.east_region
}

# ─────────────────────────────────────────────────────────────────────────────
# Cloud NAT (enables outbound internet for private nodes / pods)
# ─────────────────────────────────────────────────────────────────────────────

resource "google_compute_router_nat" "central" {
  name                               = "nat-central"
  router                             = google_compute_router.central.name
  region                             = var.central_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_router_nat" "west" {
  name                               = "nat-west"
  router                             = google_compute_router.west.name
  region                             = var.west_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_router_nat" "east" {
  name                               = "nat-east"
  router                             = google_compute_router.east.name
  region                             = var.east_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
