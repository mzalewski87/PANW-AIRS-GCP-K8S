#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  teardown-all.sh – Full teardown of the AIRS environment on GCP
#
#  Runs the destroy sequence in the correct order:
#  1. K8s namespaces (ai-chatbot, ai-api-chatbot)
#  2. Helm release pan-cni (ai-runtime-security)
#  3. terraform destroy in SCM application_project (peering)
#  4. terraform destroy in SCM security_project (FW + LB + VPCs)
#  5. terraform destroy in SCM panw-discovery onboarding (cloud account)
#  6. terraform destroy in our root TF (GKE + App VPC + IAM + bucket)
#  7. Cleanup of residue SAs (in case they remain)
#
#  AFTER teardown DO MANUALLY (no API support):
#  - SCM UI: Cloud Account Manager → remove cloud account
#  - SCM UI: Folder Management → remove folder gcp-airs (or whatever it's called)
#  - CSP: Deployment Profile → Deactivate firewalls (release credits)
#
#  USAGE:
#    ./scripts/teardown-all.sh \
#      --scm-deployment /path/to/gcp-ai-webinarN_AIRS_GCP_us-central1_HASH \
#      --scm-discovery  /path/to/panw-discovery-TSGID-onboarding/gcp \
#      [--yes]            # skip interactive confirmations
#
#  PREREQUISITES:
#  - gcloud authenticated to the project
#  - kubectl context on the cluster
#  - terraform >= 1.6 with modules initialised in each directory
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

# ─────────────────────────────────────────
# CLI parameters
# ─────────────────────────────────────────
SCM_DEPLOYMENT=""
SCM_DISCOVERY=""
AUTO_YES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --scm-deployment) SCM_DEPLOYMENT="$2"; shift 2;;
    --scm-discovery)  SCM_DISCOVERY="$2";  shift 2;;
    --yes)            AUTO_YES="--yes";    shift;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0;;
    *)
      echo "❌ Unknown argument: $1"; exit 1;;
  esac
done

if [ -z "$SCM_DEPLOYMENT" ] || [ -z "$SCM_DISCOVERY" ]; then
  echo "❌ Required parameters: --scm-deployment, --scm-discovery"
  echo "   Run with --help"
  exit 1
fi

PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || \
  grep '^project_id' terraform.tfvars 2>/dev/null | head -1 | awk -F'"' '{print $2}' || \
  gcloud config get-value project 2>/dev/null)
REGION=$(terraform output -raw region 2>/dev/null || echo "us-central1")
CLUSTER=$(terraform output -raw gke_cluster_name 2>/dev/null || echo "airs-ai-cluster")

# ─────────────────────────────────────────
# Pre-flight check
# ─────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  TEARDOWN AIRS GCP – Full removal of resources               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Project:                $PROJECT_ID"
echo "  Region:                 $REGION"
echo "  GKE Cluster:            $CLUSTER"
echo "  SCM deployment dir:     $SCM_DEPLOYMENT"
echo "  SCM discovery dir:      $SCM_DISCOVERY"
echo "  Root TF dir (working):  $(pwd)"
echo ""

for D in "$SCM_DEPLOYMENT/architecture/application_project" \
         "$SCM_DEPLOYMENT/architecture/security_project" \
         "$SCM_DISCOVERY"; do
  if [ ! -d "$D" ]; then
    echo "❌ Directory does not exist: $D"
    exit 1
  fi
done

if [ ! -f "main.tf" ] || [ ! -f "terraform.tfstate" ]; then
  echo "❌ No main.tf or terraform.tfstate in the current directory."
  echo "   Run the script from the deployment directory (with our root TF)."
  exit 1
fi

if [ "$AUTO_YES" != "--yes" ]; then
  echo "⚠️  THIS WILL REMOVE EVERYTHING. Last chance to cancel."
  read -p "Type 'yes' to continue: " CONFIRM
  [ "$CONFIRM" != "yes" ] && { echo "Cancelled."; exit 0; }
fi

START=$(date +%s)

# ─────────────────────────────────────────
# Step 1: K8s namespaces
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1️⃣  K8s namespaces (ai-chatbot, ai-api-chatbot)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if gcloud container clusters get-credentials "$CLUSTER" --region="$REGION" --project="$PROJECT_ID" 2>/dev/null; then
  kubectl delete namespace ai-chatbot ai-api-chatbot --timeout=120s --ignore-not-found 2>&1
else
  echo "  ⚠️  Cluster $CLUSTER unavailable – skipping (will be removed in step 6)"
fi

# ─────────────────────────────────────────
# Step 2: Helm pan-cni
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2️⃣  Helm release ai-runtime-security (pan-cni daemonset)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if helm list -A 2>/dev/null | grep -q ai-runtime-security; then
  helm uninstall ai-runtime-security -n kube-system 2>&1
else
  echo "  ✅ Helm release does not exist – skipping"
fi

# ─────────────────────────────────────────
# Step 3: SCM application_project
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3️⃣  terraform destroy in SCM application_project (peering)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

(cd "$SCM_DEPLOYMENT/architecture/application_project" && terraform destroy -auto-approve 2>&1 | tail -10)

# ─────────────────────────────────────────
# Step 4: SCM security_project
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4️⃣  terraform destroy in SCM security_project (FW + LB + VPCs)"
echo "    (This may take 10-15 min)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

(cd "$SCM_DEPLOYMENT/architecture/security_project" && terraform destroy -auto-approve 2>&1 | tail -15)

# ─────────────────────────────────────────
# Step 5: SCM discovery onboarding
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5️⃣  terraform destroy in SCM discovery onboarding"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

(cd "$SCM_DISCOVERY" && terraform destroy -auto-approve 2>&1 | tail -10)

# ─────────────────────────────────────────
# Step 6: Root TF
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "6️⃣  terraform destroy in root TF (GKE + App VPC + IAM + bucket)"
echo "    (This may take 10-15 min – removing GKE)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

terraform destroy -auto-approve 2>&1 | tail -15

# ─────────────────────────────────────────
# Step 7: Residue SAs cleanup
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "7️⃣  Cleanup residue Service Accounts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RESIDUE=$(gcloud iam service-accounts list --project="$PROJECT_ID" \
  --format="value(email)" 2>/dev/null | \
  grep -E "airs|panw" | grep -v compute@developer | grep -v gcp-sa- || true)

if [ -n "$RESIDUE" ]; then
  echo "  Found residue SAs:"
  echo "$RESIDUE" | sed 's/^/    /'
  for SA in $RESIDUE; do
    gcloud iam service-accounts delete "$SA" --project="$PROJECT_ID" --quiet 2>&1 | head -2
  done
else
  echo "  ✅ No residue SAs – clean"
fi

# ─────────────────────────────────────────
# Final verification
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Final state verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "VPCs (expected: 0):"
gcloud compute networks list --project="$PROJECT_ID" 2>&1 | tail -5
echo ""
echo "Compute instances (expected: 0):"
gcloud compute instances list --project="$PROJECT_ID" 2>&1 | tail -3
echo ""
echo "GKE clusters (expected: 0):"
gcloud container clusters list --project="$PROJECT_ID" 2>&1 | tail -3
echo ""
echo "Custom service accounts (expected: no airs/panw):"
gcloud iam service-accounts list --project="$PROJECT_ID" --format="value(email)" 2>&1 | grep -v compute@developer | grep -v gcp-sa- || echo "  (clean)"

END=$(date +%s)
ELAPSED=$(( (END - START) / 60 ))

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ TEARDOWN COMPLETE (${ELAPSED} min)                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "🔴 DO MANUALLY (no API support):"
echo ""
echo "  1. CSP UI → Products → Software/Cloud NGFW Credits"
echo "     → find the Deployment Profile → 'Deactivate firewalls'"
echo "     → This frees Software NGFW credits for new firewalls"
echo ""
echo "  2. (Optional) SCM UI → AI Security → Cloud Account Manager"
echo "     → cloud account usually CAN'T be removed via UI – this is NOT a problem"
echo "     → on a new deployment the Add Protections wizard will generate a new"
echo "       discovery TF to the same cloud account"
echo ""
echo "  ✅ DO NOT REMOVE the firewall config folder (e.g. 'gcp-airs') in SCM!"
echo "     The folder holds the entire config: zones, interfaces, loopbacks,"
echo "     Logical Router, NAT, security policy, AI security profile, decryption."
echo "     On a new deployment pick the same folder in the Add Protections wizard"
echo "     → new firewalls will automatically inherit the full config."
echo ""
echo "     After a new security_project apply check the LB IPs in the outputs:"
echo "       cd <new-template>/architecture/security_project && terraform output"
echo "     If the ILB IP changed → SCM UI → Configuration → Variables"
echo "       → \$ILB / \$ELB → update values → Push Config"
echo "     With the same CIDRs the ILB IP usually stays at 10.1.2.253 (static)."
echo ""
echo "After step 1 (CSP) you can do a fresh deployment from scratch."
