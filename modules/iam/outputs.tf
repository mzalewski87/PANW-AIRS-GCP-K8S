output "gke_sa_email" {
  description = "GKE nodes Service Account email"
  value       = google_service_account.gke.email
}

output "gke_sa_id" {
  description = "GKE Service Account ID"
  value       = google_service_account.gke.id
}

output "ai_app_sa_email" {
  description = "AI application Service Account email"
  value       = google_service_account.ai_app.email
}

output "ai_app_sa_id" {
  description = "AI application Service Account ID"
  value       = google_service_account.ai_app.id
}

output "ai_app_sa_name" {
  description = "AI application SA full resource name (for Workload Identity binding)"
  value       = google_service_account.ai_app.name
}
