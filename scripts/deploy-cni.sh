#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  deploy-cni.sh – PAN CNI Deployment for GKE
#
#  ⚠️  THIS SCRIPT DOES NOT INSTALL THE CNI AUTOMATICALLY
#
#  🔴 IMPORTANT – chart selection:
#  The Helm chart from the SCM-generated TF ZIP (cn-series-airs-helm) has a BUG on
#  GKE Dataplane V2 – it creates the EndpointSlice with `conditions: {}` (instead of
#  `ready: true`), so Cilium does not forward VXLAN traffic to the firewall.
#  Per community testing, use the community helm chart `r-airs-cni/airs-cni`,
#  which produces the correct EndpointSlice + SubnetInfo CRD.
#
#  Script:
#  1. Removes the old manual DaemonSet (if present)
#  2. Annotates namespace ai-chatbot
#  3. Prints install instructions for the community helm chart (PRIMARY)
#     and the SCM helm chart (FALLBACK – only if the community chart isn't available)
#
#  PREREQUISITES:
#  - VM-Series firewall Connected in SCM
#  - Trust VPC FW rule includes Pod/Service CIDR
#    (./scripts/fix-fw-trust-sources.sh)
#  - SCM configured: static routes + NAT for Pod CIDR
#    (see docs/SCM_CONFIGURATION_REQUIRED.md)
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || grep 'project_id' terraform.tfvars | head -1 | awk -F'"' '{print $2}')
REGION=$(terraform output -raw region 2>/dev/null || echo "us-central1")
CLUSTER_NAME=$(terraform output -raw gke_cluster_name 2>/dev/null || echo "airs-ai-cluster")

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " PAN CNI Deployment – Network Intercept for GKE"
echo "══════════════════════════════════════════════════════════════════"
echo ""
echo " Project: $PROJECT_ID"
echo " Cluster: $CLUSTER_NAME"
echo " Region:  $REGION"
echo ""
echo " 🔴 NOTE: SCM helm chart (cn-series-airs-helm) DOES NOT WORK correctly"
echo "    on GKE Dataplane V2 – it creates an EndpointSlice with 'conditions: {}',"
echo "    so Cilium drops VXLAN packets to the firewall."
echo "    PRIMARY chart: r-airs-cni/airs-cni (community) – see instructions below."
echo "    Per community testing on GKE Dataplane V2."
echo ""

# Get credentials
gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" --project "$PROJECT_ID" 2>/dev/null || true

# ─────────────────────────────────────────
# Cleanup old manual DaemonSet (if exists)
# ─────────────────────────────────────────
echo "Checking for old manual DaemonSet..."
if kubectl get daemonset pan-cni -n kube-system &>/dev/null; then
  HELM_MANAGED=$(kubectl get daemonset pan-cni -n kube-system -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)
  if [ "$HELM_MANAGED" = "Helm" ]; then
    echo "  ✅ pan-cni is Helm-managed — leaving it alone"
  else
    echo "  ⚠️  pan-cni is NOT Helm-managed — deleting old DaemonSet..."
    kubectl delete daemonset pan-cni -n kube-system --ignore-not-found=true
    kubectl delete configmap pan-cni-config -n kube-system --ignore-not-found=true
    echo "  ✅ Old DaemonSet removed"
  fi
else
  echo "  INFO: No old DaemonSet — OK"
fi

echo ""

# ─────────────────────────────────────────
# Annotate namespace
# ─────────────────────────────────────────
echo "Annotating namespace ai-chatbot..."
if kubectl get namespace ai-chatbot &>/dev/null; then
  kubectl annotate namespace ai-chatbot \
    paloaltonetworks.com/firewall=pan-fw \
    --overwrite
  kubectl annotate namespace ai-chatbot \
    paloaltonetworks.com/subnetfirewall=kube-system/bypass-metadata \
    --overwrite
  echo "  ✅ Namespace ai-chatbot annotated:"
  echo "       firewall=pan-fw                              (CNI chaining)"
  echo "       subnetfirewall=kube-system/bypass-metadata   (Workload Identity)"
else
  echo "  ⚠️  Namespace ai-chatbot does not exist — annotate after deploy-app.sh"
fi

echo ""
echo "══════════════════════════════════════════════════"
echo " NEXT STEPS (do these manually):"
echo "══════════════════════════════════════════════════"
echo ""
echo " 1. Configure SCM (if not already done):"
echo "    → see docs/SCM_CONFIGURATION_REQUIRED.md"
echo "    → static routes + NAT for 10.100.0.0/16 and 10.200.0.0/20"
echo "    → Push Config"
echo ""
echo " 2. Fix trust VPC FW rule (if not already done):"
echo "    ./scripts/fix-fw-trust-sources.sh"
echo "    # Adds Pod CIDR (10.100.0.0/16) and Service CIDR (10.200.0.0/20)"
echo "    # to source_ranges – otherwise VXLAN packets from the pod get dropped"
echo ""
echo " 3. Install PAN CNI – PRIMARY: community helm chart (works on GKE Dataplane V2):"
echo ""
echo "    helm repo add r-airs-cni https://rweglarz.github.io/c-airs-helm/"
echo "    helm repo update"
echo "    helm install airs r-airs-cni/airs-cni -n kube-system \\"
echo "      --set deployTo=gke \\"
echo "      --set 'endpoints[0].ip'=<TRUST_ILB_IP> \\"
echo "      --set 'fwtrustcidr=10.1.2.0/24'"
echo ""
echo "    # Find TRUST_ILB_IP like this:"
echo "    # gcloud compute forwarding-rules list --project=<PROJ> --filter='region:us-central1' \\"
echo "    #   --format='value(IPAddress)' --filter='IPProtocol=UDP'"
echo ""
echo " 3b. FALLBACK – SCM helm chart (NOT recommended on GKE Dataplane V2):"
echo "     Creates an EndpointSlice with 'conditions: {}' → Cilium won't route."
echo "     Use ONLY if the community helm chart is unavailable."
echo ""
echo "     cd <unzipped-folder>/architecture/helm"
echo "     sed -i '' 's/fwtrustcidr: \"\"/fwtrustcidr: \"10.1.2.0\\/24\"/' values.yaml"
echo "     helm install ai-runtime-security . -n kube-system --values values.yaml"
echo "     # After install you MUST manually patch the EndpointSlice:"
echo "     kubectl patch endpointslice pan-ngfw-svc-endpoints -n kube-system --type=json \\"
echo "       -p='[{\"op\":\"replace\",\"path\":\"/endpoints/0/conditions\",\"value\":{\"ready\":true,\"serving\":true,\"terminating\":false}}]'"
echo ""
echo " 4. Restart pan-cni and pods:"
echo "    kubectl rollout restart daemonset/pan-cni -n kube-system"
echo "    kubectl rollout restart deployment/ai-chatbot -n ai-chatbot"
echo ""
echo " 5. Verification:"
echo "    helm list -A"
echo "    kubectl get pods -n kube-system -l k8s-app=pan-cni"
echo "    kubectl get endpointslice -n kube-system pan-ngfw-svc-endpoints -o yaml | grep -A3 conditions"
echo "    kubectl get pods -n ai-chatbot   # should be Ready 1/1"
echo ""
echo "══════════════════════════════════════════════════"
