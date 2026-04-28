#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  deploy-app.sh – Build and deploy BOTH AI Chatbot apps to GKE
#  Run after: terraform apply
#
#  Uses Google Cloud Build to build images (no local Docker required)
#
#  Deploys:
#  1. ai-chatbot (namespace ai-chatbot) – Network Intercept demo
#  2. api-chatbot (namespace ai-api-chatbot) – API Runtime Intercept demo
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

# ─────────────────────────────────────────
# Pull outputs from Terraform
# ─────────────────────────────────────────
echo "📦 Loading configuration from Terraform outputs..."

PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || echo "")
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(grep 'project_id' terraform.tfvars 2>/dev/null | head -1 | awk -F'"' '{print $2}' || echo "")
fi

if [ -z "$PROJECT_ID" ]; then
  echo "❌ Cannot determine project_id. Set the PROJECT_ID env var or run terraform apply."
  echo "   Usage: PROJECT_ID=your-project ./scripts/deploy-app.sh"
  exit 1
fi

REGION=$(terraform output -raw region 2>/dev/null || echo "us-central1")
CLUSTER_NAME=$(terraform output -raw gke_cluster_name 2>/dev/null || echo "airs-ai-cluster")
REGISTRY_URL=$(terraform output -raw artifact_registry_url 2>/dev/null || echo "${REGION}-docker.pkg.dev/${PROJECT_ID}/airs-ai-chatbot")

# Pull allowed_mgmt_cidrs from terraform output or terraform.tfvars
ALLOWED_CIDRS_RAW=$(terraform output -json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Look for allowed_mgmt_cidrs directly or in variables
    if 'allowed_mgmt_cidrs' in data:
        cidrs = data['allowed_mgmt_cidrs'].get('value', ['0.0.0.0/0'])
    else:
        cidrs = ['0.0.0.0/0']
    print(','.join(cidrs))
except:
    print('0.0.0.0/0')
" 2>/dev/null || echo "0.0.0.0/0")

# Fallback: parse from terraform.tfvars if output failed
if [ "$ALLOWED_CIDRS_RAW" = "0.0.0.0/0" ]; then
  TFVARS_CIDRS=$(grep '^allowed_mgmt_cidrs' terraform.tfvars 2>/dev/null | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' || echo "")
  if [ -n "$TFVARS_CIDRS" ]; then
    ALLOWED_CIDRS_RAW="$TFVARS_CIDRS"
  fi
fi

# Convert to YAML format (list of CIDRs)
ALLOWED_CIDRS_YAML=""
IFS=',' read -ra CIDR_ARRAY <<< "$ALLOWED_CIDRS_RAW"
for cidr in "${CIDR_ARRAY[@]}"; do
  cidr=$(echo "$cidr" | tr -d ' "')
  # Validation: check this is a valid CIDR (x.x.x.x/y)
  if echo "$cidr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
    ALLOWED_CIDRS_YAML="${ALLOWED_CIDRS_YAML}
    - \"${cidr}\""
  fi
done

# If no CIDR validates, fall back to 0.0.0.0/0
if [ -z "$ALLOWED_CIDRS_YAML" ]; then
  ALLOWED_CIDRS_YAML='
    - "0.0.0.0/0"'
  ALLOWED_CIDRS_RAW="0.0.0.0/0"
fi

echo "  Project ID:    $PROJECT_ID"
echo "  Region:        $REGION"
echo "  Cluster:       $CLUSTER_NAME"
echo "  Registry URL:  $REGISTRY_URL"
echo "  Allowed CIDRs: $ALLOWED_CIDRS_RAW"
echo ""

# ─────────────────────────────────────────
# Configure kubectl
# ─────────────────────────────────────────
echo "🔧 Configuring kubectl..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region "$REGION" \
  --project "$PROJECT_ID"

# ═══════════════════════════════════════════════════════════════════
# APP 1: Network Intercept Chatbot (ai-chatbot)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔵 Deploying: AI Chatbot (Network Intercept)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

NI_IMAGE_TAG="${REGISTRY_URL}/chatbot:latest"
echo "  Image: $NI_IMAGE_TAG"

echo "🐳 Building Docker image (ai-chatbot) via Cloud Build..."
gcloud builds submit kubernetes/app/ \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --tag "$NI_IMAGE_TAG" \
  --quiet

echo "✅ ai-chatbot image built and pushed to Artifact Registry"

# Create namespace and SA (Terraform only creates GCP infra; this script creates K8s objects)
kubectl create namespace ai-chatbot --dry-run=client -o yaml | kubectl apply -f -

# ─────────────────────────────────────────
# Namespace annotations for pan-cni (idempotent — safe to re-run)
# ─────────────────────────────────────────
# 1. firewall=pan-fw → pan-cni hooks pods in this namespace (CNI chaining)
# 2. subnetfirewall=kube-system/bypass-metadata → traffic to 169.254.169.254 bypasses
#    the firewall (Workload Identity must fetch its token directly from GCP metadata).
#    The SubnetInfo CRD `bypass-metadata` is created by the community helm chart.
#    Without this annotation pods can't fetch a token → Gemini API call fails.
kubectl annotate namespace ai-chatbot \
  paloaltonetworks.com/firewall=pan-fw --overwrite
kubectl annotate namespace ai-chatbot \
  paloaltonetworks.com/subnetfirewall=kube-system/bypass-metadata --overwrite

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ai-chatbot-ksa
  namespace: ai-chatbot
  annotations:
    iam.gke.io/gcp-service-account: "airs-ai-app-sa@${PROJECT_ID}.iam.gserviceaccount.com"
  labels:
    app: ai-chatbot
    app.kubernetes.io/managed-by: deploy-app-script
    airs-inspect: "true"
EOF

# ConfigMap with project_id
kubectl create configmap ai-chatbot-env \
  --namespace=ai-chatbot \
  --from-literal=GCP_PROJECT_ID="$PROJECT_ID" \
  --from-literal=VERTEX_AI_LOCATION="$REGION" \
  --dry-run=client -o yaml | kubectl apply -f -

# Substitute placeholder in deployment and apply
DEPLOY_YAML=$(cat kubernetes/app/deployment.yaml)
DEPLOY_YAML="${DEPLOY_YAML//PROJECT_ID/$PROJECT_ID}"
echo "$DEPLOY_YAML" | kubectl apply -f -

# Apply service YAML and set IP ACL
kubectl apply -f kubernetes/app/service.yaml
kubectl patch svc ai-chatbot -n ai-chatbot --type merge \
  -p "{\"spec\":{\"loadBalancerSourceRanges\":[\"${ALLOWED_CIDRS_RAW}\"]}}" 2>/dev/null || true

echo "⏳ Waiting for ai-chatbot to be ready..."
kubectl rollout status deployment/ai-chatbot \
  --namespace=ai-chatbot \
  --timeout=300s

echo "✅ AI Chatbot (Network Intercept) deployed!"

# ═══════════════════════════════════════════════════════════════════
# APP 2: API Runtime Intercept Chatbot (api-chatbot)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🟢 Deploying: API Chatbot (API Runtime Intercept)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

API_IMAGE_TAG="${REGISTRY_URL}/api-chatbot:latest"
echo "  Image: $API_IMAGE_TAG"

echo "🐳 Building Docker image (api-chatbot) via Cloud Build..."
gcloud builds submit kubernetes/api-chatbot/ \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --tag "$API_IMAGE_TAG" \
  --quiet

echo "✅ api-chatbot image built and pushed to Artifact Registry"

# ── CONFIG BEFORE deployment (secret + configmaps) ──
# These must be set BEFORE applying the deployment, otherwise pods start with empty values!

# Pull AIRS config from terraform.tfvars BEFORE substitution
AIRS_API_KEY=$(grep '^airs_api_key' terraform.tfvars 2>/dev/null | head -1 | awk -F'"' '{print $2}' || echo "")
AIRS_PROFILE=$(grep '^airs_security_profile_name' terraform.tfvars 2>/dev/null | head -1 | awk -F'"' '{print $2}' || echo "airs-api-chatbot-profile")
AIRS_ENDPOINT=$(grep '^airs_api_endpoint' terraform.tfvars 2>/dev/null | head -1 | awk -F'"' '{print $2}' || echo "https://service.api.aisecurity.paloaltonetworks.com")

echo "  AIRS Profile:  $AIRS_PROFILE"
echo "  AIRS Endpoint: $AIRS_ENDPOINT"
echo "  AIRS API Key:  ${AIRS_API_KEY:+***set***}${AIRS_API_KEY:-NOT SET}"

# Substitute ALL placeholders in deployment YAML (don't apply yet)
API_DEPLOY_YAML=$(cat kubernetes/api-chatbot/deployment.yaml)
API_DEPLOY_YAML="${API_DEPLOY_YAML//__PROJECT_ID__/$PROJECT_ID}"
API_DEPLOY_YAML="${API_DEPLOY_YAML//REGISTRY_PLACEHOLDER\/api-chatbot:latest/$API_IMAGE_TAG}"
API_DEPLOY_YAML="${API_DEPLOY_YAML//__AIRS_PROFILE__/$AIRS_PROFILE}"
API_DEPLOY_YAML="${API_DEPLOY_YAML//__AIRS_ENDPOINT__/$AIRS_ENDPOINT}"

# Create namespace and SA (if not present – may already exist from Terraform)
kubectl create namespace ai-api-chatbot --dry-run=client -o yaml | kubectl apply -f -
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-chatbot-sa
  namespace: ai-api-chatbot
  annotations:
    iam.gke.io/gcp-service-account: "airs-ai-app-sa@${PROJECT_ID}.iam.gserviceaccount.com"
  labels:
    app: api-chatbot
EOF

# ConfigMap with project_id (BEFORE deployment!)
kubectl create configmap api-chatbot-env \
  --namespace=ai-api-chatbot \
  --from-literal=GCP_PROJECT_ID="$PROJECT_ID" \
  --from-literal=GCP_LOCATION="$REGION" \
  --dry-run=client -o yaml | kubectl apply -f -

# AIRS API Key – create K8s Secret (BEFORE deployment!)
if [ -n "$AIRS_API_KEY" ]; then
  echo "🔑 AIRS API Key found in terraform.tfvars – configuring AIRS scanning"
  kubectl create secret generic airs-api-secret \
    --from-literal=AIRS_API_KEY="$AIRS_API_KEY" \
    -n ai-api-chatbot \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "⚠️  AIRS API Key not set in terraform.tfvars – AIRS scanning disabled"
  echo "   Set airs_api_key in terraform.tfvars and re-run deploy-app.sh"
  kubectl create secret generic airs-api-secret \
    --from-literal=AIRS_API_KEY="" \
    -n ai-api-chatbot \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ── NOW apply the deployment (ConfigMap has correct values from placeholder substitution) ──
echo "$API_DEPLOY_YAML" | kubectl apply -f -

# Apply service YAML and set IP ACL
kubectl apply -f kubernetes/api-chatbot/service.yaml
kubectl patch svc api-chatbot -n ai-api-chatbot --type merge \
  -p "{\"spec\":{\"loadBalancerSourceRanges\":[\"${ALLOWED_CIDRS_RAW}\"]}}" 2>/dev/null || true

# Force pod restart so they pick up the latest secret/configmap
echo "🔄 Restarting api-chatbot pods (so they read the latest secret/configmap)..."
kubectl rollout restart deployment/api-chatbot -n ai-api-chatbot

echo "⏳ Waiting for api-chatbot to be ready..."
kubectl rollout status deployment/api-chatbot \
  --namespace=ai-api-chatbot \
  --timeout=300s

echo "✅ API Chatbot (API Runtime Intercept) deployed!"

# ─────────────────────────────────────────
# Summary
# ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Both apps deployed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📦 Network Intercept chatbot (ai-chatbot):"
kubectl get pods -n ai-chatbot
echo ""
echo "📦 API Runtime Intercept chatbot (api-chatbot):"
kubectl get pods -n ai-api-chatbot
echo ""
echo "🌐 Public IPs (limited to: $ALLOWED_CIDRS_RAW):"
NI_IP=$(kubectl get svc -n ai-chatbot ai-chatbot -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending...>")
API_IP=$(kubectl get svc -n ai-api-chatbot api-chatbot -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending...>")
echo "   Network Intercept: http://$NI_IP"
echo "   API Runtime:       http://$API_IP"
echo ""
echo "🔀 Alternative access (port-forward, no IP restrictions):"
echo "   kubectl port-forward svc/ai-chatbot 8080:80 -n ai-chatbot"
echo "   kubectl port-forward svc/api-chatbot 8081:80 -n ai-api-chatbot"
echo ""
echo "📋 Next steps:"
echo "   1. Generate traffic: ./scripts/generate-traffic.sh"
echo "   2. SCM onboarding:   see docs/DEPLOYMENT_GUIDE.md"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
