# ═══════════════════════════════════════════════════════════════════
#  Root module variables
#  AIRS Network Intercept + API Runtime Intercept – GCP
#
#  NOTE: Firewall VPCs (mgmt, untrust, trust) are created by SCM-generated TF.
#  Our Terraform creates ONLY the Application VPC for GKE.
# ═══════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────
# GCP Project
# ─────────────────────────────────────────
variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region (e.g. us-central1)"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone (e.g. us-central1-a)"
  type        = string
  default     = "us-central1-a"
}

# ─────────────────────────────────────────
# Network – Application VPC (the only VPC we create)
# Firewall VPCs (mgmt, untrust, trust) are created by SCM
# ─────────────────────────────────────────
variable "app_subnet_cidr" {
  description = "Application subnet CIDR (GKE nodes) – SCM peers its Trust VPC with this network"
  type        = string
  default     = "10.0.2.0/24"
}

variable "gke_pods_cidr" {
  description = "CIDR for GKE pods (secondary range)"
  type        = string
  default     = "10.100.0.0/16"
}

variable "gke_services_cidr" {
  description = "CIDR for GKE services (secondary range)"
  type        = string
  default     = "10.200.0.0/20"
}

# ─────────────────────────────────────────
# GKE
# ─────────────────────────────────────────
variable "gke_cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "airs-ai-cluster"
}

variable "gke_node_count" {
  description = "Number of GKE nodes in the pool"
  type        = number
  default     = 2
}

variable "gke_machine_type" {
  description = "GKE node machine type"
  type        = string
  default     = "e2-standard-4"
}

variable "gke_min_node_count" {
  description = "Minimum number of nodes (autoscaling)"
  type        = number
  default     = 1
}

variable "gke_max_node_count" {
  description = "Maximum number of nodes (autoscaling)"
  type        = number
  default     = 4
}

# ─────────────────────────────────────────
# Vertex AI
# ─────────────────────────────────────────
variable "vertex_ai_model" {
  description = "Vertex AI model (Gemini) to use"
  type        = string
  default     = "gemini-flash-latest"
}

variable "vertex_ai_endpoint_name" {
  description = "Vertex AI endpoint name"
  type        = string
  default     = "airs-gemini-endpoint"
}

# ─────────────────────────────────────────
# AIRS API Runtime Intercept
# ─────────────────────────────────────────
variable "airs_api_key" {
  description = <<-EOT
    AIRS (AI Runtime Security) API key – required for API Runtime Intercept.
    Generate it in the Strata Cloud Portal:
    https://apps.paloaltonetworks.com → AI Runtime Security → Settings → API Keys
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

# 🔴 NO DEFAULT ON PURPOSE. This must be the EXACT profile name from YOUR SCM
# tenant (SCM → AI Runtime Security → API Security → Profiles). A wrong or
# invented name is NOT rejected at deploy time — the AIRS API answers
# HTTP 400 `AI Profile not found` on every scan, and because the app fails
# OPEN the chatbot keeps replying while nothing is actually being scanned.
# A stale default is therefore worse than no default: it looks like it works.
variable "airs_security_profile_name" {
  description = "EXACT name of the AI security profile from your SCM tenant (e.g. GCP-AI-WEBINAR). Required – verify with scripts/verify-airs-profile.sh before deploying."
  type        = string

  validation {
    condition     = length(trimspace(var.airs_security_profile_name)) > 0
    error_message = "airs_security_profile_name must be set to the exact profile name from your SCM tenant. Find it in SCM → AI Runtime Security → API Security → Profiles."
  }
}

variable "airs_api_endpoint" {
  description = "AIRS API endpoint URL (US region – default)"
  type        = string
  default     = "https://service.api.aisecurity.paloaltonetworks.com"
}

# ─────────────────────────────────────────
# Access control – IP ACL for chatbots
# ─────────────────────────────────────────
variable "allowed_mgmt_cidrs" {
  description = <<-EOT
    List of CIDRs allowed to access the chatbots (LoadBalancer).
    ⚠️ SET this to your public IP before deployment!
    deploy-app.sh reads this variable and sets loadBalancerSourceRanges on the K8s services.
    Default 0.0.0.0/0 = OPEN TO THE WORLD (insecure!).
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ─────────────────────────────────────────
# Labels
# ─────────────────────────────────────────
variable "labels" {
  description = "GCP labels for resources (visible in SCM as tags)"
  type        = map(string)
  default = {
    project     = "airs-webinar"
    environment = "demo"
    managed-by  = "terraform"
  }
}
