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
# ⚠️ Must be a model ID that Vertex AI serves, not a Gemini API alias.
# The moving aliases (gemini-flash-latest, gemini-pro-latest) exist only on
# generativelanguage.googleapis.com and 404 on Vertex – pin an explicit version.
variable "vertex_ai_model" {
  description = "Vertex AI model (Gemini) to use – an explicit version, e.g. gemini-3.8-flash. Passed to both chatbots by deploy-app.sh."
  type        = string
  default     = "gemini-3.8-flash"
}

# ⚠️ Not the same thing as `region`. Gemini 3.x is served ONLY on the "global"
# location (host aiplatform.googleapis.com, no region prefix) – a regional value
# such as us-central1 returns 404 for it. Use a region only for a model that is
# actually published there (e.g. gemini-2.5-*, retired on 2026-10-20).
variable "vertex_ai_location" {
  description = "Vertex AI location the chatbots call: \"global\" (default) or a region that serves vertex_ai_model"
  type        = string
  default     = "global"
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

# ─────────────────────────────────────────
# SCM discovery log bucket
# ─────────────────────────────────────────
# Leave empty for the normal order (Terraform first, then onboarding): a bucket
# named <project_id>-airs-logs is created and you copy that name into the SCM
# wizard.
#
# Set it only when the Cloud Account was onboarded BEFORE this Terraform ran and
# you named a bucket of your own there. The log sink then targets that bucket
# instead of creating a second one. Getting this wrong is silent — SCM watches
# one bucket, the sink fills another, and discovery just never sees any traffic.
variable "scm_log_bucket_name" {
  description = "Name of a pre-existing GCS bucket that SCM Cloud Account onboarding was pointed at. Empty = create <project_id>-airs-logs and use that."
  type        = string
  default     = ""
}

variable "airs_api_endpoint" {
  description = "AIRS API endpoint URL (US region – default)"
  type        = string
  default     = "https://service.api.aisecurity.paloaltonetworks.com"
}

# ─────────────────────────────────────────
# AIRS AI Gateway Intercept (Portkey)
#
# These four are NOT consumed by any Terraform resource – the gateway lives
# outside GCP and every object it needs (integration, guardrail, provider,
# config) is created in the Portkey UI. They are declared here so that
# terraform.tfvars stays the single place for demo configuration, and so
# Terraform does not reject them as undeclared variables.
# scripts/deploy-gw-chatbot.sh reads them straight out of terraform.tfvars.
#
# Setup walkthrough: docs/AI_GATEWAY_SETUP.md
# ─────────────────────────────────────────
variable "portkey_api_key" {
  description = <<-EOT
    Portkey workspace API key for the AI Gateway chatbot.
    Portkey → Workspace → API Keys. This is a data-plane key: it works against
    the gateway host (aigw.portkey.ai) but not the control-plane API.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

# 🔴 The config is what BINDS the AIRS guardrail to the model provider.
# A Portkey guardrail on its own is inert, and a request sent with no config
# is happily routed to the model with NO inspection at all. Same fail-open
# shape as a wrong AIRS profile name: the chatbot answers, nothing is scanned.
# deploy-gw-chatbot.sh aborts when this is empty rather than deploying a demo
# that proves nothing.
variable "portkey_config_id" {
  description = "Portkey config slug (pc-***) binding the AIRS guardrail to the Vertex AI provider. Required for AI Gateway Intercept – see docs/AI_GATEWAY_SETUP.md § 6."
  type        = string
  default     = ""
}

variable "portkey_provider_slug" {
  description = <<-EOT
    Portkey provider slug (Vertex AI), used INSTEAD of portkey_config_id when the
    workspace inspects traffic with an Organization Guardrail rather than a saved
    config. Set exactly one of the two. Inspection is proven by the deploy-time
    probe in scripts/deploy-gw-chatbot.sh, not by which of the two you picked.
    See docs/AI_GATEWAY_SETUP.md § 6b.
  EOT
  type        = string
  default     = ""
}

variable "portkey_gateway_url" {
  description = "Portkey AI Gateway base URL (OpenAI-compatible endpoint)"
  type        = string
  default     = "https://aigw.portkey.ai/v1"
}

# Claude on Vertex AI is not served in us-central1 (404). Point the Portkey
# provider at the "global" location – a regional endpoint such as us-east5 may
# serve the model but with zero default quota (429). The location is configured
# on the Portkey provider, not here; this is only the model name the app asks for.
#
# The `anthropic.` prefix is not cosmetic: Portkey maps the model name onto a
# Vertex publisher path, and a plain name builds publishers/GOOGLE/... which does
# not serve Claude – a 404 that looks exactly like a wrong region. Prefix and
# region are independent failure modes; fixing one still leaves the other 404ing.
# Some providers accept the plain name – if the prefixed form 404s, try it.
variable "gw_model" {
  description = "Model name requested through the AI Gateway (Claude Haiku on Vertex AI). The anthropic. prefix selects publishers/anthropic – see docs/AI_GATEWAY_SETUP.md § 5."
  type        = string
  default     = "anthropic.claude-haiku-5-5"
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
