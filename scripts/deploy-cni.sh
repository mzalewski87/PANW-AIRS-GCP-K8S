#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  deploy-cni.sh – PAN CNI Deployment for GKE
#
#  ⚠️  THIS SCRIPT DOES NOT INSTALL THE CNI AUTOMATICALLY
#
#  🔴 HARD PREREQUISITE – GKE version:
#  GKE Dataplane V2 on 1.35.1-gke.1516000+ writes "cniVersion": "1.1.0" into the
#  node's CNI conflist, so containerd 2.x issues the CNI STATUS verb. pan-cni
#  (every published tag) answers `unknown CNI_COMMAND: STATUS` → all nodes go
#  NotReady. The preflight below aborts on such clusters. Pin the cluster below
#  that threshold (modules/gke: min_master_version) before installing the CNI.
#
#  ✅ CHART SELECTION – use the SCM-generated chart (PANW-supported path).
#  The chart in the SCM TF ZIP is byte-for-byte the official PANW chart
#  (github.com/PaloAltoNetworks/prisma-airs-helm) with the GKE branches
#  pre-resolved. On GKE Dataplane V2 it creates the EndpointSlice with
#  `conditions: {}`; patch it once after install (step 3 below) – verified to
#  persist, the EndpointSlice is chart-managed and has no controller to revert it.
#  It also ships the `subnetinfos` CRD with NO CR instances – apply
#  kubernetes/cni/subnetinfo-bypass.yaml (step 4) or the metadata-server bypass
#  annotation dangles and Workload Identity breaks.
#  With steps 3+4 the community chart `r-airs-cni/airs-cni` is NOT required.
#
#  Script:
#  1. Aborts if the GKE version is incompatible with pan-cni (see below)
#  2. Removes the old manual DaemonSet (if present)
#  3. Annotates namespace ai-chatbot
#  4. Prints install instructions for the SCM/official helm chart
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
echo " ✅ Chart: the SCM-generated one (= official PANW prisma-airs-helm)."
echo "    On GKE Dataplane V2 it emits an EndpointSlice with 'conditions: {}';"
echo "    patch it once after install (step 3) – the patch persists."
echo ""

# Get credentials
gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" --project "$PROJECT_ID" 2>/dev/null || true

# ─────────────────────────────────────────
# 🔴 PREFLIGHT: GKE version gate (CNI spec 1.1.0)
#
# GKE Dataplane V2 on 1.35.1-gke.1516000+ writes "cniVersion": "1.1.0" into
# 10-gke-cni.conflist. containerd 2.x then issues the CNI STATUS verb, which
# pan-cni (all published tags 4.0.0/4.0.1/4.0.2 advertise up to CNI 0.4.0 only)
# rejects with `unknown CNI_COMMAND: STATUS`. Result: EVERY node goes NotReady
# with NetworkPluginNotReady, cluster-wide outage. Recovery = helm uninstall.
# ─────────────────────────────────────────
MASTER_VERSION=$(gcloud container clusters describe "$CLUSTER_NAME" \
  --region "$REGION" --project "$PROJECT_ID" \
  --format="value(currentMasterVersion)" 2>/dev/null || echo "")

if [ -n "$MASTER_VERSION" ]; then
  echo "Preflight: GKE version $MASTER_VERSION"

  # Compare against the 1.35.1-gke.1516000 threshold
  VER_MINOR=$(echo "$MASTER_VERSION" | awk -F. '{printf "%d%03d", $1, $2}')
  if [ "$VER_MINOR" -ge 1035 ]; then
    echo ""
    echo "  ❌ ABORT: GKE $MASTER_VERSION uses CNI spec 1.1.0 in the Dataplane V2 conflist."
    echo "     pan-cni does not implement the CNI STATUS verb and will take EVERY node"
    echo "     NotReady (NetworkPluginNotReady) the moment the DaemonSet rolls out."
    echo ""
    echo "     Verify on a node:"
    echo "       kubectl debug node/<node> -it --image=busybox --profile=general -- \\"
    echo "         grep cniVersion /host/etc/cni/net.d/10-gke-cni.conflist"
    echo "       # \"1.1.0\" → do NOT install pan-cni"
    echo ""
    echo "     Recreate the cluster on a supported version (see DEPLOYMENT_GUIDE § 3.2)."
    echo "     Recovery if you already installed it: helm uninstall <release> -n kube-system"
    echo ""
    exit 1
  fi
  echo "  ✅ Version OK for pan-cni"
  echo ""
fi

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
  # 🔴 Namespace-LOCAL reference. pan-cni 4.0.2 rejects cross-namespace SubnetInfo
  # refs and the pod sandbox fails outright, hanging in ContainerCreating.
  kubectl annotate namespace ai-chatbot \
    paloaltonetworks.com/subnetfirewall=ai-chatbot/bypass-metadata-and-internal \
    --overwrite
  echo "  ✅ Namespace ai-chatbot annotated:"
  echo "       firewall=pan-fw                                          (CNI chaining)"
  echo "       subnetfirewall=ai-chatbot/bypass-metadata-and-internal   (Workload Identity)"
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
echo " 3. Install PAN CNI – SCM-generated chart (= official PANW prisma-airs-helm):"
echo ""
echo "    # Verify values.yaml first – 'endpoints' MUST be the UDP trust ILB IP:"
echo "    cd <unzipped-folder>/architecture/helm"
echo "    grep -E 'endpoints|cniimage|clusterid' values.yaml"
echo ""
echo "    # Find TRUST_ILB_IP (requires ip_protocol=UDP on the SCM internal LB,"
echo "    # see DEPLOYMENT_GUIDE section 7.5a):"
echo "    # gcloud compute forwarding-rules list --project=<PROJ> \\"
echo "    #   --filter='region:us-central1 AND IPProtocol=UDP' --format='value(IPAddress)'"
echo ""
echo "    sed -i '' 's/fwtrustcidr: \"\"/fwtrustcidr: \"10.1.2.0\\/24\"/' values.yaml"
echo "    # SCM ships a moving 'pan-cni:latest' tag – pin it:"
echo "    sed -i '' 's|pan-cni:latest|pan-cni:4.0.2|' values.yaml"
echo "    helm install ai-runtime-security . -n kube-system --values values.yaml"
echo ""
echo "    # REQUIRED on GKE Dataplane V2 – the chart writes 'conditions: {}',"
echo "    # so Cilium won't route to the endpoint. One-time patch, it persists:"
echo "    kubectl patch endpointslice pan-ngfw-svc-endpoints -n kube-system --type=json \\"
echo "      -p='[{\"op\":\"replace\",\"path\":\"/endpoints/0/conditions\",\"value\":{\"ready\":true,\"serving\":true,\"terminating\":false}}]'"
echo ""
echo "    # REQUIRED – the chart installs the subnetinfos CRD but no CR instances."
echo "    # Without these the bypass-metadata annotation dangles and Workload"
echo "    # Identity (Gemini access) breaks the moment CNI chaining goes live:"
echo "    kubectl apply -f kubernetes/cni/subnetinfo-bypass.yaml"
echo "    kubectl get subnetinfo -n ai-chatbot"
echo ""
echo " 4. Restart pan-cni and pods:"
echo "    kubectl rollout restart daemonset/pan-cni -n kube-system"
echo "    kubectl rollout restart deployment/ai-chatbot -n ai-chatbot"
echo ""
echo " 5. Verification:"
echo "    helm list -A"
echo "    kubectl get pods -n kube-system -l k8s-app=pan-cni"
echo "    kubectl get endpointslice -n kube-system pan-ngfw-svc-endpoints -o yaml | grep -A3 conditions"
echo "    kubectl get subnetinfo -n ai-chatbot   # bypass-metadata-and-internal must exist"
echo "    kubectl get pods -n ai-chatbot   # should be Ready 1/1"
echo ""
echo "══════════════════════════════════════════════════"
