output "endpoint_id" {
  description = "Vertex AI endpoint ID"
  value       = google_vertex_ai_endpoint.chatbot_endpoint.id
}

output "endpoint_name" {
  description = "Vertex AI endpoint name"
  value       = google_vertex_ai_endpoint.chatbot_endpoint.name
}

output "artifact_registry_url" {
  description = "Artifact Registry repository URL"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.chatbot.repository_id}"
}

output "vertex_ai_config_secret_id" {
  description = "Secret ID for the Vertex AI configuration"
  value       = google_secret_manager_secret.vertex_ai_config.secret_id
}

output "model_id" {
  description = "Gemini model ID"
  value       = var.model_id
}
