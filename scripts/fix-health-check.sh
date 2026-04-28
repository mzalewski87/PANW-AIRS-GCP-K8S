#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  fix-health-check.sh – Fix external LB health check (SCM bug)
#
#  PROBLEM: SCM-generated Terraform creates the External LB **HTTP** health
#  check with the wrong port:
#    http_health_check_port         = "443"            # ← bug (HTTP on 443 doesn't work)
#    http_health_check_request_path = "/php/login.php" # ← OK!
#
#  Path /php/login.php IS correct – PA-VM `interface_management_profile
#  = allow-health-checks` on HTTP/80 returns a 302 redirect for that path
#  (PA-VM web GUI endpoint). Path "/" returns 404. Only the port needs to change.
#
#  CORRECT CONFIG:
#    HTTP check, port 80, requestPath /php/login.php, host ""
#  Effect: External LB backends become HEALTHY (302 redirect = OK 2xx-3xx).
#
#  ─── TWO MODES ───
#
#  MODE 1 (DEFAULT): Live infrastructure fix
#    Edits the existing health check via `gcloud`.
#    Usage: ./scripts/fix-health-check.sh [TEMPLATE_NAME]
#
#  MODE 2: Pre-apply fix in terraform.tfvars
#    Edits terraform.tfvars in application_project BEFORE apply
#    (preferred – fix is permanent, no manual action after apply).
#    Usage: ./scripts/fix-health-check.sh --terraform <scm-template-dir>
#
#    <scm-template-dir> = unzipped SCM template directory, e.g.:
#    /path/to/<name>_AIRS_GCP_us-central1_HASH/
#    (script edits architecture/application_project/terraform.tfvars)
#
#  PREREQUISITES:
#  - MODE 1: gcloud CLI with compute.healthChecks.update rights
#  - MODE 2: write access to terraform.tfvars
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

# ─────────────────────────────────────────
# Mode 2: Pre-apply edit of terraform.tfvars
# ─────────────────────────────────────────
if [ "${1:-}" = "--terraform" ]; then
  SCM_DIR="${2:-}"
  if [ -z "$SCM_DIR" ] || [ ! -d "$SCM_DIR" ]; then
    echo "❌ Usage: $0 --terraform <path-to-SCM-template-dir>"
    echo "   Example: $0 --terraform ~/scm-templates/<TEMPLATE>_AIRS_GCP_US-CENTRAL1_HASH"
    exit 1
  fi

  # Health check config is in security_project (lbs_external block), NOT in application_project
  TFVARS_SEC="$SCM_DIR/architecture/security_project/terraform.tfvars"
  if [ ! -f "$TFVARS_SEC" ]; then
    echo "❌ Could not find $TFVARS_SEC"
    exit 1
  fi

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  PRE-APPLY FIX: security_project/terraform.tfvars            ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  File: $TFVARS_SEC"
  echo ""

  echo "📋 State BEFORE:"
  grep -E "(http_)?health_check_(port|request_path|host)" "$TFVARS_SEC" 2>/dev/null | sed 's/^/    /' || echo "    (no parameters – maybe already fixed)"
  echo ""

  # Backup
  cp "$TFVARS_SEC" "${TFVARS_SEC}.bak"
  echo "💾 Backup: ${TFVARS_SEC}.bak"

  # Fix (sed -i '' for macOS BSD, sed -i without '' for GNU)
  if [[ "$(uname)" == "Darwin" ]]; then
    SED_INLINE=(-i '')
  else
    SED_INLINE=(-i)
  fi

  # ELB: change ONLY the port (443→80). Path /php/login.php stays – it's correct.
  sed "${SED_INLINE[@]}" -E 's|http_health_check_port[[:space:]]*=[[:space:]]*"443"|http_health_check_port         = "80"|' "$TFVARS_SEC"
  # request_path /php/login.php stays (PA-VM web GUI endpoint, returns 302 redirect on HTTP/80)

  # ILB: TCP check port 443 STAYS – that one works (PA-VM mgmt webGUI listens on 443)
  # DO NOT touch: health_check_port = "443" (that's for the ILB TCP check)

  echo ""
  echo "📋 State AFTER:"
  grep -E "(http_)?health_check_(port|request_path|host)" "$TFVARS_SEC" 2>/dev/null | sed 's/^/    /' || echo "    (no parameters – check manually)"
  echo ""

  echo "✅ Fixed. Now run:"
  echo ""
  echo "  cd $SCM_DIR/architecture/security_project"
  echo "  terraform init"
  echo "  terraform plan"
  echo "  terraform apply"
  echo ""
  echo "  # After security_project apply, only then do application_project:"
  echo "  cd ../application_project"
  echo "  terraform init && terraform apply -auto-approve"
  echo ""
  exit 0
fi

# ─────────────────────────────────────────
# Mode 1: Live infrastructure fix (gcloud)
# ─────────────────────────────────────────
PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || \
  grep '^project_id' terraform.tfvars 2>/dev/null | head -1 | awk -F'"' '{print $2}' || \
  gcloud config get-value project 2>/dev/null)
REGION=$(terraform output -raw region 2>/dev/null || echo "us-central1")

TEMPLATE_NAME="${1:-}"

# Auto-detect template name if not provided
if [ -z "$TEMPLATE_NAME" ]; then
  echo "🔍 Looking for the external-lb health check..."
  EXT_HC=$(gcloud compute health-checks list \
    --project="$PROJECT_ID" \
    --filter="name~external-lb AND region:$REGION" \
    --format="value(name)" 2>/dev/null | head -1)

  if [ -z "$EXT_HC" ]; then
    echo "❌ Did not find an external-lb health check in region $REGION"
    echo ""
    echo "Pass the template name as an argument: $0 <name>"
    echo "Or use the pre-apply mode (better): $0 --terraform <scm-template-dir>"
    exit 1
  fi
  echo "  ✅ Found: $EXT_HC"
else
  EXT_HC="${TEMPLATE_NAME}-external-lb-${REGION}"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " LIVE INFRASTRUCTURE FIX: $EXT_HC"
echo "══════════════════════════════════════════════════════════════"
echo " Project: $PROJECT_ID"
echo " Region:  $REGION"
echo ""

echo "📋 State BEFORE fix:"
gcloud compute health-checks describe "$EXT_HC" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format="value(httpHealthCheck.port,httpHealthCheck.requestPath,httpHealthCheck.host)" 2>&1 || {
  echo "❌ Health check does not exist – check the name"
  exit 1
}

echo ""
echo "🔧 Updating: port=80, requestPath=/php/login.php, host=\"\""
gcloud compute health-checks update http "$EXT_HC" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --port=80 \
  --request-path="/php/login.php" \
  --host="" 2>&1

echo ""
echo "📋 State AFTER fix:"
gcloud compute health-checks describe "$EXT_HC" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format="yaml(httpHealthCheck)" 2>&1

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " ✅ Health check fixed"
echo ""
echo " NOTE: Backends become HEALTHY only once the firewall responds."
echo " Requirements:"
echo "  1. Firewall registered in SCM (Connected)"
echo "  2. Loopback interfaces configured (section 8.3 of the GUIDE)"
echo "  3. Management profile 'allow-health-checks' (HTTP+HTTPS) on the loopbacks"
echo "  4. Push Config done"
echo ""
echo " 💡 Next time use the pre-apply mode (permanent fix):"
echo "    $0 --terraform <scm-template-dir>"
echo ""
echo " Verify backends:"
EXT_BS=$(echo "$EXT_HC" | sed 's/-us-central1$//')
echo "    gcloud compute backend-services get-health $EXT_BS \\"
echo "      --region=$REGION --project=$PROJECT_ID"
echo "══════════════════════════════════════════════════════════════"
