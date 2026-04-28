#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  cleanup.sh – Remove all AIRS demo resources
#  Run when you want to wipe the environment after webinar/demo
#
#  WARNING: This is a DESTRUCTIVE operation! Removes:
#  - Kubernetes applications (both chatbots)
#  - Terraform infrastructure (VPC, GKE, VM-Series prereqs)
#  - Docker images in Artifact Registry
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║    ⚠️  AIRS Demo Cleanup – REMOVING RESOURCES                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────
# Confirm operation
# ─────────────────────────────────────────
read -p "❓ Are you sure you want to remove ALL demo resources? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "❌ Cancelled."
  exit 0
fi

# ─────────────────────────────────────────
# Pull configuration
# ─────────────────────────────────────────
PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || echo "")
REGION=$(terraform output -raw region 2>/dev/null || echo "us-central1")
CLUSTER_NAME=$(terraform output -raw gke_cluster_name 2>/dev/null || echo "airs-ai-cluster")

echo ""
echo "🔧 Configuration:"
echo "  Project:  $PROJECT_ID"
echo "  Region:   $REGION"
echo "  Cluster:  $CLUSTER_NAME"
echo ""

# ─────────────────────────────────────────
# Step 1: Remove Kubernetes resources
# ─────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Step 1: Removing Kubernetes resources..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Try to connect to the cluster
if gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region "$REGION" --project "$PROJECT_ID" 2>/dev/null; then

  echo "  Removing namespace ai-chatbot..."
  kubectl delete namespace ai-chatbot --ignore-not-found --timeout=60s 2>/dev/null || true

  echo "  Removing namespace ai-api-chatbot..."
  kubectl delete namespace ai-api-chatbot --ignore-not-found --timeout=60s 2>/dev/null || true

  echo "  Removing PAN-CNI DaemonSet..."
  kubectl delete -f kubernetes/cni/pan-cni-daemonset.yaml --ignore-not-found 2>/dev/null || true

  echo "  ✅ Kubernetes resources removed"
else
  echo "  ⚠️  Cannot connect to GKE cluster (may already be gone)"
fi

# ─────────────────────────────────────────
# Step 2: Remove Docker images from Artifact Registry
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🐳 Step 2: Removing Docker images..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

REGISTRY_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/airs-ai-chatbot"

for IMAGE in chatbot api-chatbot; do
  echo "  Removing ${REGISTRY_URL}/${IMAGE}..."
  gcloud artifacts docker images delete "${REGISTRY_URL}/${IMAGE}" \
    --delete-tags --quiet 2>/dev/null || echo "  ⚠️  Image ${IMAGE} not found"
done
echo "  ✅ Docker images removed"

# ─────────────────────────────────────────
# Step 3: Terraform destroy
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🏗️  Step 3: Terraform destroy..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

terraform destroy -auto-approve

# ─────────────────────────────────────────
# Step 4: Local cleanup
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧹 Step 4: Local cleanup..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

rm -f deployment-summary-*.txt
rm -f kubeconfig
echo "  ✅ Temporary files removed"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║    ✅ Cleanup completed successfully!                        ║"
echo "║    All AIRS demo resources have been removed.                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "⚠️  NOTE: If you deployed VM-Series via SCM-generated TF,"
echo "   you must run 'terraform destroy' separately in the SCM-TF directory."
echo ""
