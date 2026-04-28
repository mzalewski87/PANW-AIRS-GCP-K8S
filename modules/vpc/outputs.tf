# ─────────────────────────────────────────
# Application VPC outputs
#
# NOTE: Output names trust_network_id / trust_subnet_id are kept
# for backward compatibility with the GKE module. In reality this is
# the Application VPC (airs-app-vpc), NOT the SCM Trust VPC.
# SCM creates its own Trust VPC and peers it with our App VPC.
# ─────────────────────────────────────────
output "app_network_id" {
  description = "Application VPC ID (airs-app-vpc)"
  value       = google_compute_network.app.id
}

output "app_network_name" {
  description = "Application VPC name – provide in SCM as the spoke VPC for peering"
  value       = google_compute_network.app.name
}

output "app_subnet_id" {
  description = "Application subnet ID (airs-app-subnet)"
  value       = google_compute_subnetwork.app.id
}

output "app_subnet_name" {
  description = "Application subnet name"
  value       = google_compute_subnetwork.app.name
}

output "app_subnet_cidr" {
  description = "Application subnet CIDR"
  value       = google_compute_subnetwork.app.ip_cidr_range
}

output "gke_pods_range_name" {
  description = "Secondary range name for GKE pods"
  value       = "gke-pods"
}

output "gke_services_range_name" {
  description = "Secondary range name for GKE services"
  value       = "gke-services"
}

# ─────────────────────────────────────────
# Legacy aliases – backward compatibility with the GKE module
# The GKE module references trust_network_id / trust_subnet_id
# These aliases map App VPC → the old output names
# ─────────────────────────────────────────
output "trust_network_id" {
  description = "[LEGACY ALIAS] → app_network_id. Backward compat for GKE module."
  value       = google_compute_network.app.id
}

output "trust_subnet_id" {
  description = "[LEGACY ALIAS] → app_subnet_id. Backward compat for GKE module."
  value       = google_compute_subnetwork.app.id
}
