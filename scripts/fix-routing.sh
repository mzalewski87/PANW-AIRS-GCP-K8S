#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  fix-routing.sh – Fix GCP routing for AIRS Network Intercept
#
#  Fixes two issues:
#  1. Bypass route with priority 500 blocks traffic through the firewall
#  2. Missing VPC Peering on the Trust VPC side
#
#  RUN: ./scripts/fix-routing.sh
#  PREREQUISITES: gcloud CLI with compute.networkAdmin rights
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || grep 'project_id' terraform.tfvars | head -1 | awk -F'"' '{print $2}')
APP_VPC="airs-app-vpc"

echo ""
echo "══════════════════════════════════════════════════"
echo " fix-routing.sh – AIRS Network Intercept Routing"
echo "══════════════════════════════════════════════════"
echo " Project: $PROJECT_ID"
echo ""

# ─────────────────────────────────────────
# Detect Trust VPC name (SCM-generated, varies per template)
# ─────────────────────────────────────────
TRUST_VPC=$(gcloud compute networks list --project="$PROJECT_ID" \
  --filter="name ~ trust-vpc" --format="value(name)" | head -1)

if [ -z "$TRUST_VPC" ]; then
  echo "❌ Did not find a Trust VPC in project $PROJECT_ID"
  echo "   Check: gcloud compute networks list --project=$PROJECT_ID"
  exit 1
fi
echo " Trust VPC: $TRUST_VPC"
echo ""

# ─────────────────────────────────────────
# FIX 1: Bypass route priority
# ─────────────────────────────────────────
echo "FIX 1: Looking for the bypass route..."

BYPASS_ROUTE=$(gcloud compute routes list --project="$PROJECT_ID" \
  --filter="network:${APP_VPC} AND name ~ 'bypass'" \
  --format="value(name)" | head -1)

if [ -n "$BYPASS_ROUTE" ]; then
  BYPASS_PRIORITY=$(gcloud compute routes describe "$BYPASS_ROUTE" \
    --project="$PROJECT_ID" --format="value(priority)")

  echo "  Found: $BYPASS_ROUTE (priority: $BYPASS_PRIORITY)"

  if [ "$BYPASS_PRIORITY" -lt 1000 ]; then
    echo "  ⚠️  Priority $BYPASS_PRIORITY is too high — traffic bypasses the firewall!"
    echo "  Removing and re-creating with priority 1100..."

    gcloud compute routes delete "$BYPASS_ROUTE" \
      --project="$PROJECT_ID" --quiet
    echo "  ✅ Old bypass route removed"

    gcloud compute routes create "$BYPASS_ROUTE" \
      --network="$APP_VPC" \
      --destination-range=0.0.0.0/0 \
      --next-hop-gateway=default-internet-gateway \
      --priority=1100 \
      --project="$PROJECT_ID"
    echo "  ✅ Bypass route re-created with priority 1100"
  else
    echo "  ✅ Priority $BYPASS_PRIORITY is OK (>= 1000)"
  fi
else
  echo "  INFO: No bypass route — skipping"
fi

echo ""

# ─────────────────────────────────────────
# FIX 1b: Default route
# ─────────────────────────────────────────
echo "FIX 1b: Looking for the default route..."

DEFAULT_ROUTE=$(gcloud compute routes list --project="$PROJECT_ID" \
  --filter="network:${APP_VPC} AND destRange=0.0.0.0/0 AND name ~ 'default-route'" \
  --format="value(name)" | head -1)

if [ -n "$DEFAULT_ROUTE" ]; then
  echo "  Found: $DEFAULT_ROUTE"
  echo "  ⚠️  Default route may shadow the peering route — removing..."
  gcloud compute routes delete "$DEFAULT_ROUTE" \
    --project="$PROJECT_ID" --quiet
  echo "  ✅ Default route removed"
else
  echo "  INFO: No default route — skipping"
fi

echo ""

# ─────────────────────────────────────────
# FIX 2: VPC Peering (Trust VPC → App VPC)
# ─────────────────────────────────────────
echo "FIX 2: VPC Peering Trust VPC → App VPC..."

PEERING_NAME="${TRUST_VPC}-to-${APP_VPC}"

if gcloud compute networks peerings describe "$PEERING_NAME" \
     --network="$TRUST_VPC" \
     --project="$PROJECT_ID" &>/dev/null; then
  echo "  ✅ Peering $PEERING_NAME already exists"
else
  # Try alternate name
  EXISTING=$(gcloud compute networks peerings list \
    --network="$TRUST_VPC" --project="$PROJECT_ID" \
    --filter="peerNetwork ~ ${APP_VPC}" --format="value(name)" 2>/dev/null | head -1)

  if [ -n "$EXISTING" ]; then
    echo "  ✅ Peering exists as: $EXISTING"
  else
    echo "  ⚠️  No peering — creating..."
    gcloud compute networks peerings create "$PEERING_NAME" \
      --network="$TRUST_VPC" \
      --peer-project="$PROJECT_ID" \
      --peer-network="$APP_VPC" \
      --import-custom-routes \
      --export-custom-routes \
      --project="$PROJECT_ID"
    echo "  ✅ Peering $PEERING_NAME created"
  fi
fi

echo ""

# ─────────────────────────────────────────
# VERIFICATION
# ─────────────────────────────────────────
echo "══════════════════════════════════════════════════"
echo " VERIFICATION:"
echo "══════════════════════════════════════════════════"
echo ""
echo "Routes 0.0.0.0/0 in ${APP_VPC}:"
gcloud compute routes list --project="$PROJECT_ID" \
  --filter="network:${APP_VPC} AND destRange=0.0.0.0/0" \
  --format="table(name,destRange,nextHopGateway,nextHopPeering,priority)" \
  --sort-by=priority

echo ""
echo "VPC Peering:"
gcloud compute networks peerings list --project="$PROJECT_ID" \
  --format="table(name,network,peerNetwork,state)"

echo ""
echo "══════════════════════════════════════════════════"
echo "  ✅ Routing fixed!"
echo ""
echo "  Next steps:"
echo "  1. Configure SCM: static routes + NAT for Pod CIDR"
echo "     (see docs/SCM_CONFIGURATION_REQUIRED.md)"
echo "  2. Push Config in SCM"
echo "  3. kubectl rollout restart deployment/ai-chatbot -n ai-chatbot"
echo "══════════════════════════════════════════════════"
