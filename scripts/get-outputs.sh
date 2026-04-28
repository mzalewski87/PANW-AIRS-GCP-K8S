#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  get-outputs.sh – Pull and format Terraform outputs
#  for use during SCM configuration and deployment docs
#
#  NOTE: This script shows outputs from OUR Terraform.
#  The firewall VPCs (mgmt, untrust, trust) and the VM-Series IP
#  are created by SCM-generated Terraform – you'll find those
#  values in the SCM TF outputs (architecture/security_project).
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║    AIRS – GCP deployment summary (our Terraform)             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Pull all outputs as JSON
OUTPUTS=$(terraform output -json 2>/dev/null)

get_output() {
  echo "$OUTPUTS" | jq -r ".[\"$1\"].value // \"N/A\"" 2>/dev/null || echo "N/A"
}

PROJECT_ID=$(get_output "project_id")
REGION=$(get_output "region")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DATA FOR SCM CONFIGURATION (Strata Cloud Manager)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  GCP Project ID:          $PROJECT_ID"
echo "  Region:                  $REGION"
echo ""
echo "  ⚠️  SCM CLOUD ACCOUNT ONBOARDING – COPY these values:"
echo "  ┌────────────────────────────────────────────────────────┐"
echo "  │  Bucket Name:  $(get_output 'scm_onboarding_bucket_name')"
echo "  │  Project ID:   $PROJECT_ID"
echo "  └────────────────────────────────────────────────────────┘"
echo "  ⚠️  DO NOT type manually! Copy the EXACT value above."
echo ""
echo "  --- APPLICATION VPC (ours – GKE + apps) ---"
echo "  VPC Name:                $(get_output 'app_vpc_name')"
echo "  Subnet CIDR:             $(get_output 'app_subnet_cidr')"
echo ""
echo "  ℹ️  Firewall VPCs (mgmt, untrust, trust) are created by SCM-generated TF."
echo "  Find those VPC details in the SCM Terraform outputs"
echo "  (architecture/security_project after terraform apply)."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  GKE CLUSTER"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Cluster Name:            $(get_output 'gke_cluster_name')"
echo "  Workload Identity Pool:  $(get_output 'gke_workload_identity_pool')"
echo "  Get Credentials:         $(get_output 'gke_get_credentials_cmd')"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VERTEX AI"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Endpoint Name:           $(get_output 'vertex_ai_endpoint_name')"
echo "  Model ID:                $(get_output 'vertex_ai_model_id')"
echo "  Artifact Registry:       $(get_output 'artifact_registry_url')"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SERVICE ACCOUNTS (created by our TF)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  GKE SA:                  $(get_output 'gke_service_account_email')"
echo "  AI App SA:               $(get_output 'ai_app_service_account_email')"
echo ""
echo "  ℹ️  VM-Series SA and Tag Collector SA are created by SCM-generated TF."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AIRS API RUNTIME INTERCEPT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  API Key Secret Name:     $(get_output 'airs_api_secret_name')"
echo "  Security Profile:        $(get_output 'airs_security_profile_name')"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Save the data above – you'll need it for SCM configuration  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Save to a file
OUTPUT_FILE="deployment-summary-$(date +%Y%m%d-%H%M%S).txt"
{
  echo "AIRS Deployment Summary – $(date)"
  echo "================================="
  echo "Project: $PROJECT_ID | Region: $REGION"
  echo ""
  echo "App VPC Name: $(get_output 'app_vpc_name')"
  echo "App Subnet CIDR: $(get_output 'app_subnet_cidr')"
  echo "GKE Cluster: $(get_output 'gke_cluster_name')"
  echo "Logs Bucket: $(get_output 'scm_onboarding_bucket_name')"
  echo ""
  echo "NOTE: VM-Series IP, mgmt/untrust/trust VPC details – see SCM TF outputs"
} > "$OUTPUT_FILE"

echo "📄 Summary saved to: $OUTPUT_FILE"
