# ═══════════════════════════════════════════════════════════════════
#  Outputs – Application Infrastructure
#
#  After terraform apply run: ./scripts/get-outputs.sh
#  Enter the VPC values into the SCM wizard (Add Protections).
# ═══════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────
# GCP Project
# ─────────────────────────────────────────
output "project_id" {
  description = "GCP project ID"
  value       = var.project_id
}

output "region" {
  description = "GCP region"
  value       = var.region
}

output "zone" {
  description = "GCP zone"
  value       = var.zone
}

# ─────────────────────────────────────────
# Application VPC – to be entered in SCM
# ─────────────────────────────────────────
output "app_vpc_name" {
  description = "Application VPC name – provide in SCM as the spoke VPC for peering"
  value       = module.vpc.app_network_name
}

output "app_subnet_cidr" {
  description = "Application subnet CIDR"
  value       = module.vpc.app_subnet_cidr
}

# ─────────────────────────────────────────
# GKE
# ─────────────────────────────────────────
output "gke_cluster_name" {
  description = "GKE cluster name"
  value       = module.gke.cluster_name
}

output "gke_cluster_endpoint" {
  description = "GKE cluster API endpoint"
  value       = module.gke.endpoint
  sensitive   = true
}

output "gke_get_credentials_cmd" {
  description = "Command to fetch kubeconfig"
  value       = "gcloud container clusters get-credentials ${module.gke.cluster_name} --region ${var.region} --project ${var.project_id}"
}

output "gke_workload_identity_pool" {
  description = "Workload Identity pool"
  value       = module.gke.workload_identity_pool
}

# ─────────────────────────────────────────
# Vertex AI
# ─────────────────────────────────────────
output "vertex_ai_endpoint_name" {
  description = "Vertex AI endpoint name"
  value       = module.vertex_ai.endpoint_name
}

output "vertex_ai_model_id" {
  description = "Gemini model ID"
  value       = module.vertex_ai.model_id
}

output "artifact_registry_url" {
  description = "Artifact Registry repository URL"
  value       = module.vertex_ai.artifact_registry_url
}

# ─────────────────────────────────────────
# SCM Onboarding
# ─────────────────────────────────────────
output "airs_logs_bucket" {
  description = "GCS bucket for AIRS logs"
  value       = google_storage_bucket.airs_logs.name
}

output "scm_onboarding_bucket_name" {
  description = "⚠️ EXACT bucket name to COPY into SCM Cloud Account onboarding. Do NOT type it manually!"
  value       = google_storage_bucket.airs_logs.name
}

# ─────────────────────────────────────────
# IAM
# ─────────────────────────────────────────
output "gke_service_account_email" {
  description = "GKE node SA email"
  value       = module.iam.gke_sa_email
}

output "ai_app_service_account_email" {
  description = "AI app SA email (Workload Identity)"
  value       = module.iam.ai_app_sa_email
}

# ─────────────────────────────────────────
# SCM Deployment Info
# ─────────────────────────────────────────
output "scm_deployment_inputs" {
  description = "Inputs for the SCM Add Protections wizard"
  value = {
    gcp_project_id = var.project_id
    gcp_region     = var.region

    # Application VPC – SCM peers its Trust VPC with this
    app_vpc_name    = module.vpc.app_network_name
    app_subnet_cidr = module.vpc.app_subnet_cidr

    # Bucket name for SCM onboarding (COPY-PASTE this!)
    airs_logs_bucket = google_storage_bucket.airs_logs.name

    note = "SCM creates its own VPCs (mgmt, untrust, trust) and peers Trust with our App VPC."
  }
}

# ─────────────────────────────────────────
# AIRS API Runtime Intercept
# ─────────────────────────────────────────
output "airs_api_secret_name" {
  description = "AIRS API key Secret Manager secret name"
  value       = google_secret_manager_secret.airs_api_key.secret_id
}

output "airs_security_profile_name" {
  description = "AIRS Security Profile name (configure in SCM)"
  value       = var.airs_security_profile_name
}

# ─────────────────────────────────────────
# IP ACL
# ─────────────────────────────────────────
output "allowed_mgmt_cidrs" {
  description = "List of CIDRs allowed to access the chatbot LoadBalancers"
  value       = var.allowed_mgmt_cidrs
}
