#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  fix-untrust-web-ingress.sh – open TCP/80,443 from internet to firewall untrust
#
#  PROBLEM:
#  SCM-generated TF creates `<prefix>-allow-untrust-vpc-ingress` with source_ranges
#  containing ONLY Google ELB health-check ranges:
#    35.191.0.0/16, 130.211.0.0/22, 209.85.152.0/22, 209.85.204.0/22
#
#  Without `0.0.0.0/0` (or a specific management IP) on TCP/80,443:
#  - We can see ELB health-checks in SCM Logs ✅
#  - User curl http://<UNTRUST_ELB_IP>/health → packet drops at the GCP-level
#    BEFORE reaching the firewall → SCM Logs/Traffic empty for user requests
#
#  SYMPTOM:
#  - In SCM Logs you only see health-check sessions (from Google ranges)
#  - No user traffic in Traffic logs despite valid DNAT/Security policy
#  - curl from a laptop: HTTP=000 timeout
#
#  FIX:
#  Create a dedicated GCP FW rule `<prefix>-allow-untrust-web-from-internet`:
#    source: 0.0.0.0/0 (or ALLOWED_SOURCES env)
#    allowed: tcp:80,443
#  Per-IP/security granularity belongs in the FW security policy in SCM.
#
#  RUN:
#    ./scripts/fix-untrust-web-ingress.sh
#    # or restrict to a specific IP:
#    ALLOWED_SOURCES="203.0.113.10/32" ./scripts/fix-untrust-web-ingress.sh
#
#  NOTE: This rule is at the GCP VPC level – per-source/policy security MUST be
#  implemented on the firewall (security policy in SCM).
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || \
  grep 'project_id' terraform.tfvars | head -1 | awk -F'"' '{print $2}')

ALLOWED_SOURCES="${ALLOWED_SOURCES:-0.0.0.0/0}"
PORTS="${PORTS:-tcp:80,tcp:443}"

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " fix-untrust-web-ingress.sh – TCP web to firewall untrust"
echo "══════════════════════════════════════════════════════════════════"
echo " Project: $PROJECT_ID"
echo " Sources: $ALLOWED_SOURCES"
echo " Ports:   $PORTS"
echo ""

# ─────────────────────────────────────────
# Detect untrust VPC name (SCM-prefixed, varies per template)
# ─────────────────────────────────────────
UNTRUST_VPC=$(gcloud compute networks list --project="$PROJECT_ID" \
  --filter="name~fw-untrust-vpc" --format="value(name)" | head -1)

if [ -z "$UNTRUST_VPC" ]; then
  echo "❌ Did not find untrust VPC '*-fw-untrust-vpc' in project $PROJECT_ID"
  echo "   Deploy security_project from SCM-generated TF first"
  exit 1
fi
echo " Untrust VPC: $UNTRUST_VPC"

# Pull the prefix into the rule name (e.g. 'gcp-ai-webinar-8')
PREFIX="${UNTRUST_VPC%-fw-untrust-vpc}"
RULE_NAME="${PREFIX}-allow-untrust-web-from-internet"
echo " Rule name:   $RULE_NAME"
echo ""

# ─────────────────────────────────────────
# Create or update the rule
# ─────────────────────────────────────────
if gcloud compute firewall-rules describe "$RULE_NAME" \
     --project="$PROJECT_ID" &>/dev/null; then
  echo " Rule already exists – updating source-ranges + allowed"
  gcloud compute firewall-rules update "$RULE_NAME" \
    --project="$PROJECT_ID" \
    --source-ranges="$ALLOWED_SOURCES" \
    --rules="$PORTS"
else
  echo " Creating new rule..."
  gcloud compute firewall-rules create "$RULE_NAME" \
    --project="$PROJECT_ID" \
    --network="$UNTRUST_VPC" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules="$PORTS" \
    --source-ranges="$ALLOWED_SOURCES" \
    --priority=1000 \
    --description="Allow web traffic from internet to firewall untrust nic0. Per-source granularity on FW security policy in SCM."
fi

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " ✅ FW rule '$RULE_NAME' OK"
echo ""
echo " What's next:"
echo " 1. Make sure SCM has a NAT rule + Security policy for inbound"
echo "    (see docs/DEPLOYMENT_GUIDE.md section 8.6)"
echo " 2. Test:"
echo "    UNTRUST_ELB=\$(gcloud compute forwarding-rules list --project=\$PROJECT_ID \\"
echo "      --filter='IPProtocol=L3_DEFAULT' --format='value(IPAddress)' | head -1)"
echo "    curl -m 10 http://\$UNTRUST_ELB/health"
echo "══════════════════════════════════════════════════════════════════"
