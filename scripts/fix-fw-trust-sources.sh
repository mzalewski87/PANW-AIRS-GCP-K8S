#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  fix-fw-trust-sources.sh – fix two GCP-level FW rules for AIRS
#
#  PROBLEM 1 – TRUST VPC (SCM-managed):
#  SCM-generated TF creates `<prefix>-allow-trust-vpc-ingress` with source_ranges
#  containing only the node subnet (10.0.2.0/24) and Google health-check ranges.
#  The Pod CIDR (10.100.0.0/16) and Service CIDR (10.200.0.0/20) are NOT on the list –
#  trust VPC drops VXLAN-encap'd packets from pan-cni and direct
#  pod→firewall trust nic2 traffic.
#
#  PROBLEM 2 – APP VPC (our Terraform – modules/vpc/main.tf):
#  The `airs-app-allow-internal` rule normally allows traffic inside the App VPC
#  (10.0.2.0/24, 10.100.0.0/16, 10.200.0.0/20). After adding inbound DNAT on the
#  firewall (untrust ELB → node:NodePort), the packet returns with source = trust subnet
#  IP of the firewall (10.1.2.0/24). Without that CIDR in source_ranges → the packet drops
#  on the GCP-level FW (and the return path), inbound DNAT does not work.
#
#  Current TF definition (modules/vpc/variables.tf) has `trust_subnet_cidr`
#  as a variable with default 10.1.2.0/24 – `terraform apply` fixes it natively.
#  This script is for "live" environments where we don't want to re-apply.
#
#  SYMPTOM (when either is missing):
#  - Trust VPC: pods in CrashLoopBackOff, pod→FW timeout
#  - App VPC: external ELB → firewall → node:NodePort timeout (HTTP=000),
#             but `kubectl exec pod -- curl 10.0.2.X:NODEPORT` works
#
#  FIX:
#  Update BOTH FW rules – add the missing CIDRs.
#
#  NOTE: The trust VPC fix is LIVE and SCM `terraform apply` will overwrite it. The App VPC
#  fix is persistent (our TF already has it as the module vpc default).
#
#  RUN: ./scripts/fix-fw-trust-sources.sh
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || \
  grep 'project_id' terraform.tfvars | head -1 | awk -F'"' '{print $2}')

# Pod + Service CIDR defaults for our GKE (modules/gke/main.tf)
POD_CIDR="${POD_CIDR:-10.100.0.0/16}"
SVC_CIDR="${SVC_CIDR:-10.200.0.0/20}"
TRUST_CIDR="${TRUST_CIDR:-10.1.2.0/24}"

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " fix-fw-trust-sources.sh – patch GCP FW rules for AIRS flow"
echo "══════════════════════════════════════════════════════════════════"
echo " Project:     $PROJECT_ID"
echo " Pod CIDR:    $POD_CIDR"
echo " Svc CIDR:    $SVC_CIDR"
echo " Trust CIDR:  $TRUST_CIDR"
echo ""

# ─────────────────────────────────────────────────────────────────────
# Helper: append source ranges to FW rule if missing
# Args: $1 = rule name, $@ from $2 = CIDRs to add
# ─────────────────────────────────────────────────────────────────────
patch_rule() {
  local RULE="$1"
  shift
  local CIDRS=("$@")

  if ! gcloud compute firewall-rules describe "$RULE" --project="$PROJECT_ID" &>/dev/null; then
    echo "  ⚠️  Rule '$RULE' does not exist – skipping"
    return 0
  fi

  local CURRENT
  CURRENT=$(gcloud compute firewall-rules describe "$RULE" \
    --project="$PROJECT_ID" --format="value(sourceRanges)")

  echo "  CURRENT: $CURRENT"

  local NEW_RANGES="$CURRENT"
  local CHANGED=0
  for CIDR in "${CIDRS[@]}"; do
    if ! echo "$CURRENT" | grep -q "$CIDR"; then
      NEW_RANGES="$NEW_RANGES;$CIDR"
      CHANGED=1
    fi
  done

  if [ "$CHANGED" -eq 0 ]; then
    echo "  ✅ All CIDRs already present – skipping"
    return 0
  fi

  local NEW_CSV
  NEW_CSV=$(echo "$NEW_RANGES" | tr ';' ',')
  echo "  NEW:     $NEW_CSV"

  gcloud compute firewall-rules update "$RULE" \
    --project="$PROJECT_ID" \
    --source-ranges="$NEW_CSV" --quiet
  echo "  ✅ Rule '$RULE' updated"
}

# ─────────────────────────────────────────────────────────────────────
# 1. TRUST VPC (SCM-managed) – add Pod + Service CIDR
# ─────────────────────────────────────────────────────────────────────
echo "─────────────────────────────────────────────────────────────────"
echo " 1) TRUST VPC FW rule (SCM-managed) – add Pod/Service CIDR"
echo "─────────────────────────────────────────────────────────────────"

TRUST_RULE=$(gcloud compute firewall-rules list --project="$PROJECT_ID" \
  --filter="name~allow-trust-vpc-ingress" --format="value(name)" | head -1)

if [ -z "$TRUST_RULE" ]; then
  echo "  ⚠️  Could not find '*-allow-trust-vpc-ingress' – deploy security_project from SCM first"
else
  echo "  Rule: $TRUST_RULE"
  patch_rule "$TRUST_RULE" "$POD_CIDR" "$SVC_CIDR"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# 2. APP VPC (our Terraform) – add Trust subnet CIDR
# ─────────────────────────────────────────────────────────────────────
echo "─────────────────────────────────────────────────────────────────"
echo " 2) APP VPC FW rule (our TF) – add Trust subnet CIDR"
echo "─────────────────────────────────────────────────────────────────"
echo "  Rule: airs-app-allow-internal"
patch_rule "airs-app-allow-internal" "$TRUST_CIDR"
echo ""

echo "══════════════════════════════════════════════════════════════════"
echo " ✅ Patch complete"
echo ""
echo " What's next:"
echo " 1. Restart pods if they were in CrashLoop:"
echo "    kubectl rollout restart deployment/ai-chatbot -n ai-chatbot"
echo " 2. Test inbound through the firewall ELB:"
echo "    curl -m 10 http://<UNTRUST_ELB_IP>/health"
echo ""
echo " ⚠️  The trust VPC fix is LIVE – SCM 'terraform apply' will overwrite it."
echo "    The App VPC fix is persistent (modules/vpc/variables.tf default)."
echo "══════════════════════════════════════════════════════════════════"
