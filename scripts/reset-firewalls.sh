#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  reset-firewalls.sh – Reset all VM-Series + Tag Collector
#
#  PROBLEM: First firewall bootstrap from the SCM template sometimes hangs
#  between 'Successfully installed license key' and Device Cert retrieval.
#  No error messages in the serial console – cert retrieval silently fails.
#
#  SOLUTION: A reset (soft reboot) forces a fresh bootstrap from init-cfg
#  which usually succeeds (cert fetched, SCM connection OK).
#
#  SCRIPT:
#  1. Detects all firewalls in the MIG + Tag Collector VM (by SCM template prefix)
#  2. Resets ALL of them in parallel (each has a separate mgmt interface – no conflict)
#  3. Prints verification instructions for ~10-15 min later
#
#  USAGE: ./scripts/reset-firewalls.sh [--yes]
#    --yes  skips the interactive confirmation
#
#  PREREQUISITES: gcloud CLI with compute.instances.reset rights
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || \
  grep '^project_id' terraform.tfvars 2>/dev/null | head -1 | awk -F'"' '{print $2}' || \
  gcloud config get-value project 2>/dev/null)

AUTO_YES="${1:-}"

# ─────────────────────────────────────────
# Detect firewalls and Tag Collector
# ─────────────────────────────────────────
echo "🔍 Looking for VM-Series firewalls + Tag Collector in project $PROJECT_ID..."

FW_LIST=$(gcloud compute instances list --project="$PROJECT_ID" \
  --filter="(name~fw-autoscale OR name~tc-vm) AND status=RUNNING" \
  --format="value(name,zone.basename())" 2>/dev/null)

if [ -z "$FW_LIST" ]; then
  echo "❌ Did not find VM-Series firewalls or Tag Collector in RUNNING state"
  echo "   Verify the SCM template was deployed (terraform apply in security_project)"
  exit 1
fi

echo ""
echo "📋 Instances to reset:"
echo "$FW_LIST" | awk '{printf "    • %-50s zone: %s\n", $1, $2}'
echo ""

# ─────────────────────────────────────────
# Confirmation
# ─────────────────────────────────────────
if [ "$AUTO_YES" != "--yes" ]; then
  read -p "❓ Reset ALL the instances above? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "❌ Cancelled."
    exit 0
  fi
fi

# ─────────────────────────────────────────
# Reset in parallel
# ─────────────────────────────────────────
echo ""
echo "🔄 Reset in progress..."

while IFS=$'\t' read -r FW ZONE; do
  echo "   ⏳ Reset $FW (zone $ZONE)..."
  gcloud compute instances reset "$FW" --zone="$ZONE" --project="$PROJECT_ID" --quiet 2>&1 &
done <<< "$FW_LIST"

wait

echo ""
echo "✅ All reset commands sent"
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "📋 NEXT STEPS"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo " 1. WAIT ~10-15 minutes for the new instances to fully bootstrap"
echo "    (license install, cert retrieval, SCM connection)"
echo ""
echo " 2. Verify each firewall (SSH):"
echo "    Get the mgmt IP:"
echo "      gcloud compute instances describe <fw-name> --zone=<zone> --project=$PROJECT_ID \\"
echo "        --format='value(networkInterfaces[1].accessConfigs[0].natIP)'"
echo ""
echo "    SSH + diagnostic commands (PAN-OS CLI – needs a TTY):"
echo "      ssh -i ~/.ssh/<your-key> admin@<mgmt-ip>"
echo "      > show device-certificate status"
echo "      > show panorama-status"
echo ""
echo "    Expected:"
echo "      Device Certificate status: Valid"
echo "      Last fetched status: success"
echo "      Panorama: Connected (or: Cloud Service)"
echo ""
echo " 3. In the SCM UI: Workflows → NGFW Setup → Device Management"
echo "    → Cloud Managed Devices tab"
echo "    → Verify firewalls show up as 'Connected'"
echo ""
echo " 4. If Connected: continue with SCM configuration"
echo "    → docs/DEPLOYMENT_GUIDE.md section 8 (PHASE 6)"
echo "    → zones, interfaces, loopbacks, LR, NAT, security policy, push"
echo ""
echo " 5. After push config: verify backend health"
echo "    gcloud compute backend-services get-health <PREFIX>-internal-lb \\"
echo "      --region=\$REGION --project=$PROJECT_ID"
echo ""
echo " 6. Full diagnostics: ./scripts/diagnose-airs.sh"
echo "══════════════════════════════════════════════════════════════"
