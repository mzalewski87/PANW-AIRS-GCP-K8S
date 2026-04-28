# ═══════════════════════════════════════════════════════════════════
#  Prisma AIRS – GCP AI Security Webinar
#  Root module – Application Infrastructure + SCM Prerequisites
#
#  This Terraform creates ONLY the application infrastructure:
#  - Application VPC (GKE + AI apps)
#  - GKE cluster + Workload Identity
#  - Artifact Registry + Vertex AI endpoint config
#  - GCS bucket for logs (SCM discovery)
#  - SCM onboarding prerequisites (audit logs, log sink, Cloud Asset API)
#
#  IMPORTANT: Firewall VPCs (mgmt, untrust, trust) are created by SCM-generated TF!
#  SCM peers its Trust VPC with our App VPC.
#
#  DEPLOYMENT ORDER:
#  1. terraform apply  (this file) → App VPC + GKE + Apps + SCM Prerequisites
#  2. Deploy applications (scripts/deploy-app.sh)
#  3. Generate traffic (scripts/generate-traffic.sh)
#  4. SCM: Cloud Account onboarding → download + apply SCM onboarding TF
#  5. SCM: Add Protections → download + apply SCM deployment TF
#     (creates FW VPCs, VM-Series, Tag Collector, VPC Peering)
# ═══════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────
# Enable required GCP APIs
# ─────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "dns.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com",
    "generativelanguage.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ─────────────────────────────────────────
# IAM – Service Accounts (GKE + AI App only)
# VM-Series SA and Tag Collector SA are created by SCM TF
# ─────────────────────────────────────────
module "iam" {
  source     = "./modules/iam"
  project_id = var.project_id
  labels     = var.labels

  depends_on = [google_project_service.apis]
}

# ─────────────────────────────────────────
# Application VPC – single VPC for GKE + AI apps
# SCM peers its Trust VPC with this network
# ─────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  project_id        = var.project_id
  region            = var.region
  app_subnet_cidr   = var.app_subnet_cidr
  gke_pods_cidr     = var.gke_pods_cidr
  gke_services_cidr = var.gke_services_cidr
  labels            = var.labels

  depends_on = [google_project_service.apis]
}

# ─────────────────────────────────────────
# GKE – Kubernetes cluster for AI applications
# Runs in the Application VPC
# ─────────────────────────────────────────
module "gke" {
  source = "./modules/gke"

  project_id          = var.project_id
  region              = var.region
  cluster_name        = var.gke_cluster_name
  network             = module.vpc.trust_network_id
  subnetwork          = module.vpc.trust_subnet_id
  pods_range_name     = module.vpc.gke_pods_range_name
  services_range_name = module.vpc.gke_services_range_name
  node_count          = var.gke_node_count
  machine_type        = var.gke_machine_type
  min_node_count      = var.gke_min_node_count
  max_node_count      = var.gke_max_node_count
  gke_sa_email        = module.iam.gke_sa_email
  labels              = var.labels

  depends_on = [module.vpc, module.iam]
}

# ─────────────────────────────────────────
# Vertex AI – Gemini endpoint + Artifact Registry
# ─────────────────────────────────────────
module "vertex_ai" {
  source = "./modules/vertex-ai"

  project_id       = var.project_id
  region           = var.region
  endpoint_name    = var.vertex_ai_endpoint_name
  model_id         = var.vertex_ai_model
  gke_sa_email     = module.iam.gke_sa_email
  trust_network_id = module.vpc.trust_network_id
  labels           = var.labels

  depends_on = [module.iam, module.vpc, google_project_service.apis]
}

# ─────────────────────────────────────────
# Workload Identity bindings (KSA↔GSA)
# ─────────────────────────────────────────
resource "google_service_account_iam_member" "ai_app_workload_identity" {
  service_account_id = module.iam.ai_app_sa_name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[ai-chatbot/ai-chatbot-ksa]"

  depends_on = [module.gke]
}

resource "google_service_account_iam_member" "ai_app_workload_identity_api" {
  service_account_id = module.iam.ai_app_sa_name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[ai-api-chatbot/api-chatbot-sa]"

  depends_on = [module.gke]
}

# ─────────────────────────────────────────
# Secret Manager – AIRS API Key (for api-chatbot)
# ─────────────────────────────────────────
resource "google_secret_manager_secret" "airs_api_key" {
  secret_id = "airs-api-key"
  project   = var.project_id
  labels    = var.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "airs_api_key" {
  count       = var.airs_api_key != "" ? 1 : 0
  secret      = google_secret_manager_secret.airs_api_key.id
  secret_data = var.airs_api_key
}

resource "google_secret_manager_secret_iam_member" "gke_sa_airs_key" {
  secret_id = google_secret_manager_secret.airs_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${module.iam.gke_sa_email}"
  project   = var.project_id
}

# ═══════════════════════════════════════════════════════════════════
# SCM Cloud Account Onboarding Prerequisites
# ═══════════════════════════════════════════════════════════════════

# GCS Bucket for AIRS logs and SCM discovery
resource "google_storage_bucket" "airs_logs" {
  name          = "${var.project_id}-airs-logs"
  project       = var.project_id
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  labels = var.labels
}

# Data Access Audit Logs – Vertex AI API
resource "google_project_iam_audit_config" "vertex_ai_audit" {
  project = var.project_id
  service = "aiplatform.googleapis.com"

  audit_log_config {
    log_type = "DATA_READ"
  }
}

# Logging Service Identity (prevent race condition)
resource "google_project_service_identity" "logging" {
  provider = google-beta
  project  = var.project_id
  service  = "logging.googleapis.com"

  depends_on = [google_project_service.apis]
}

# Log Router Sink – VPC Flow Logs + AI Audit Logs → GCS
resource "google_logging_project_sink" "airs_log_sink" {
  name        = "airs-scm-discovery-sink"
  project     = var.project_id
  destination = "storage.googleapis.com/${google_storage_bucket.airs_logs.name}"

  filter = <<-EOT
    (logName =~ "logs/cloudaudit.googleapis.com%2Fdata_access" AND protoPayload.methodName:("google.cloud.aiplatform."))
    OR
    (logName = "projects/${var.project_id}/logs/compute.googleapis.com%2Fvpc_flows" AND resource.labels.subnetwork_name = "airs-app-subnet")
  EOT

  unique_writer_identity = true

  depends_on = [google_storage_bucket.airs_logs, google_project_service_identity.logging]
}

resource "google_storage_bucket_iam_member" "sink_writer" {
  bucket = google_storage_bucket.airs_logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.airs_log_sink.writer_identity
}

# Cloud Asset API
resource "google_project_service" "cloudasset_api" {
  project            = var.project_id
  service            = "cloudasset.googleapis.com"
  disable_on_destroy = false
}

# ─────────────────────────────────────────
# Cloud Build permissions
# ─────────────────────────────────────────
data "google_project" "current" {
  project_id = var.project_id
}

resource "google_project_iam_member" "cloudbuild_storage_admin" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "cloudbuild_logs_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "cloudbuild_ar_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"

  depends_on = [google_project_service.apis]
}
