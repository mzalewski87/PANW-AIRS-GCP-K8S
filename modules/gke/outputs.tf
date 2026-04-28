output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.ai_cluster.name
}

output "cluster_id" {
  description = "GKE cluster ID"
  value       = google_container_cluster.ai_cluster.id
}

output "endpoint" {
  description = "GKE cluster API endpoint"
  value       = google_container_cluster.ai_cluster.endpoint
  sensitive   = true
}

output "ca_certificate" {
  description = "GKE cluster CA certificate (base64)"
  value       = google_container_cluster.ai_cluster.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "location" {
  description = "GKE cluster region/zone"
  value       = google_container_cluster.ai_cluster.location
}

output "workload_identity_pool" {
  description = "Workload Identity pool"
  value       = google_container_cluster.ai_cluster.workload_identity_config[0].workload_pool
}
