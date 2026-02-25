# ── VPC ───────────────────────────────────────────────────────────────────────

output "vpc_name" {
  description = "Name of the global VPC network."
  value       = google_compute_network.vpc_global.name
}

output "vpc_self_link" {
  description = "Self-link of the global VPC network."
  value       = google_compute_network.vpc_global.self_link
}

output "vpc_id" {
  description = "Unique identifier of the global VPC network."
  value       = google_compute_network.vpc_global.id
}

# ── Subnets ───────────────────────────────────────────────────────────────────

output "central_subnet_self_link" {
  description = "Self-link of the central subnet."
  value       = google_compute_subnetwork.central.self_link
}

output "central_subnet_id" {
  description = "ID of the central subnet."
  value       = google_compute_subnetwork.central.id
}

output "west_subnet_self_link" {
  description = "Self-link of the west subnet."
  value       = google_compute_subnetwork.west.self_link
}

output "west_subnet_id" {
  description = "ID of the west subnet."
  value       = google_compute_subnetwork.west.id
}

output "east_subnet_self_link" {
  description = "Self-link of the east subnet."
  value       = google_compute_subnetwork.east.self_link
}

output "east_subnet_id" {
  description = "ID of the east subnet."
  value       = google_compute_subnetwork.east.id
}

# ── GKE secondary range names (referenced when creating GKE clusters) ─────────

output "central_pods_range_name" {
  description = "Secondary range name for GKE pods in the central subnet."
  value       = "central-pods"
}

output "central_services_range_name" {
  description = "Secondary range name for GKE services in the central subnet."
  value       = "central-services"
}

output "west_pods_range_name" {
  description = "Secondary range name for GKE pods in the west subnet."
  value       = "west-pods"
}

output "west_services_range_name" {
  description = "Secondary range name for GKE services in the west subnet."
  value       = "west-services"
}

output "east_pods_range_name" {
  description = "Secondary range name for GKE pods in the east subnet."
  value       = "east-pods"
}

output "east_services_range_name" {
  description = "Secondary range name for GKE services in the east subnet."
  value       = "east-services"
}
