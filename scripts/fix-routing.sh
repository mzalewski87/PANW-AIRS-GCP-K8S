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

# NOTE: use `network~` (client-side regex), NOT `network:` (substring).
# The `:` operator pushes the whole filter server-side and the Compute API
# rejects `destRange=0.0.0.0/0` there ("Invalid list filter expression").
BYPASS_ROUTE=$(gcloud compute routes list --project="$PROJECT_ID" \
  --filter="network~${APP_VPC} AND name~bypass" \
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

# NOTE: destRange MUST stay in the match. Matching on the name alone also picks up
# the auto-generated subnet routes `default-route-r-*`, which GCP refuses to delete.
#
# The name match is done client-side, NOT in --filter. Two filter terms are fine,
# but adding a third makes gcloud push the whole expression server-side, and the
# Compute API then rejects destRange with:
#   Invalid value for field 'filter' ... Invalid list filter expression
# The `~` operator alone is not enough to keep evaluation local once the
# expression grows. Same class of trap as using `:` instead of `~`.
# `|| true` because grep exits 1 when nothing matches, and under `set -e` that
# would abort the script on the perfectly normal "route already removed" case
# (this script is meant to be re-runnable after every SCM apply).
DEFAULT_ROUTE=$(gcloud compute routes list --project="$PROJECT_ID" \
  --filter="network~${APP_VPC} AND destRange=0.0.0.0/0" \
  --format="value(name)" | { grep -E '^default-route-' || true; } | head -1)

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

# Detect an EXISTING peering by peer network, not by name: SCM names its own
# peering `<trust-vpc>-<app-vpc>`, which is not the name we would create.
# Matching on our name only would miss it and we would try to create a duplicate.
#
# Two gcloud traps here, both previously silent:
#   - there is no `networks peerings describe` subcommand at all;
#   - `--filter="peerNetwork ~ ..."` is rejected by the API (no such field),
#     and with stderr discarded the assignment just came back empty — which
#     under `set -e` aborted the script before FIX 2 ever ran.
# `peerings list` returns the NETWORK object with a nested peerings[] array, so
# flatten it and match the peer network URL client-side.
EXISTING=$(gcloud compute networks peerings list \
  --network="$TRUST_VPC" --project="$PROJECT_ID" \
  --flatten="peerings[]" \
  --format="value(peerings.name,peerings.network)" 2>/dev/null \
  | { grep -F "/${APP_VPC}" || true; } | awk '{print $1}' | head -1)

if [ -n "$EXISTING" ]; then
  echo "  ✅ Peering to $APP_VPC already exists: $EXISTING"
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
  --filter="network~${APP_VPC} AND destRange=0.0.0.0/0" \
  --format="table(name,destRange,nextHopGateway,nextHopPeering,priority)" \
  --sort-by=priority

echo ""
echo "VPC Peering:"
# `peerings list` returns NETWORK objects with a nested peerings[] array – the
# columns live under peerings.*, so without --flatten the table prints one row
# per network with every field blank. There is no top-level `peerNetwork`.
gcloud compute networks peerings list --project="$PROJECT_ID" \
  --flatten="peerings[]" \
  --format="table(name:label=NETWORK,
                  peerings.name:label=PEERING,
                  peerings.network.basename():label=PEER_NETWORK,
                  peerings.state:label=STATE)"

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
