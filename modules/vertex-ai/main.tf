# ═══════════════════════════════════════════════════════════════════
#  Vertex AI Module – Gemini endpoint for AI Chatbot applications
#  Traffic to/from Vertex AI is protected by AIRS VM-Series
# ═══════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────
# Artifact Registry – Docker image registry for the chatbot
# ─────────────────────────────────────────
resource "google_artifact_registry_repository" "chatbot" {
  repository_id = "airs-ai-chatbot"
  project       = var.project_id
  location      = var.region
  format        = "DOCKER"
  description   = "Docker image registry for AI Chatbot (AIRS webinar)"

  labels = var.labels
}

# ─────────────────────────────────────────
# Vertex AI Endpoint – access point for the Gemini model
# Note: Gemini 1.5/2.0 is available via the Vertex AI API without deployment.
# This endpoint is intended for an optional fine-tuned model.
# ─────────────────────────────────────────
resource "google_vertex_ai_endpoint" "chatbot_endpoint" {
  name         = var.endpoint_name
  project      = var.project_id
  location     = var.region
  display_name = "AIRS AI Chatbot Endpoint – ${var.endpoint_name}"
  description  = "Vertex AI endpoint for the AI Chatbot application protected by AIRS"

  labels = var.labels
}

# ─────────────────────────────────────────
# Secret Manager – API key / application configuration
# ─────────────────────────────────────────
resource "google_secret_manager_secret" "vertex_ai_config" {
  secret_id = "airs-vertex-ai-config"
  project   = var.project_id

  labels = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "vertex_ai_config" {
  secret = google_secret_manager_secret.vertex_ai_config.id

  secret_data = jsonencode({
    project_id    = var.project_id
    region        = var.region
    model_id      = var.model_id
    endpoint_id   = google_vertex_ai_endpoint.chatbot_endpoint.name
    endpoint_name = var.endpoint_name
  })
}

# Access for the AI app SA to this secret
resource "google_secret_manager_secret_iam_member" "ai_app_secret_access" {
  secret_id = google_secret_manager_secret.vertex_ai_config.id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.gke_sa_email}"
}

# ─────────────────────────────────────────
# VPC Service Controls / Private Service Connect
# for private Vertex AI API access from the Trust VPC
# ─────────────────────────────────────────
resource "google_compute_global_address" "vertex_ai_psc" {
  name          = "airs-vertex-ai-psc-ip"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24
  network       = var.trust_network_id

  description = "IP for Private Service Connect to Vertex AI"
}
