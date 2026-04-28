# ═══════════════════════════════════════════════════════════════════
#  IAM Module – Service Accounts for application components
#
#  NOTE: VM-Series SA and Tag Collector SA are created by SCM-generated Terraform.
#  Our module creates ONLY the SAs needed for the applications (GKE, AI App).
# ═══════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────
# Service Account – GKE Nodes
# ─────────────────────────────────────────
resource "google_service_account" "gke" {
  account_id   = "airs-gke-sa"
  display_name = "AIRS GKE Node Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "gke_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke.email}"
}

resource "google_project_iam_member" "gke_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke.email}"
}

resource "google_project_iam_member" "gke_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gke.email}"
}

resource "google_project_iam_member" "gke_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke.email}"
}

# Access to Vertex AI (calling Gemini models)
resource "google_project_iam_member" "gke_vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.gke.email}"
}

resource "google_project_iam_member" "gke_storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.gke.email}"
}

# ─────────────────────────────────────────
# Service Account – AI Application (Workload Identity)
# ─────────────────────────────────────────
resource "google_service_account" "ai_app" {
  account_id   = "airs-ai-app-sa"
  display_name = "AIRS AI Chatbot Application Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "ai_app_vertex_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.ai_app.email}"
}

resource "google_project_iam_member" "ai_app_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.ai_app.email}"
}

# NOTE: Workload Identity bindings (KSA↔GSA) live in the root main.tf
# because they require the GKE cluster to exist (Workload Identity Pool)

# Access to Secret Manager (AIRS API Key)
resource "google_project_iam_member" "ai_app_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.ai_app.email}"
}
