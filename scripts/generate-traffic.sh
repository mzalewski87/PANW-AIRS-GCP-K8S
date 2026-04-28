#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  generate-traffic.sh – Generate GCP network traffic
#
#  GOAL: Before onboarding the GCP account into SCM and generating
#  Terraform for AIRS, the apps must produce network traffic.
#  SCM uses observed traffic to:
#  - Detect VPCs and subnets where AI apps run
#  - Generate the correct inspection config
#  - Show network topology in the deployment wizard
#
#  RUN: ./scripts/generate-traffic.sh
#  PREREQUISITES: Apps deployed (scripts/deploy-app.sh)
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || \
  grep 'project_id' terraform.tfvars 2>/dev/null | head -1 | awk -F'"' '{print $2}' || \
  echo "")

REGION=$(terraform output -raw region 2>/dev/null || echo "us-central1")
CLUSTER=$(terraform output -raw gke_cluster_name 2>/dev/null || echo "airs-ai-cluster")
ZONE=$(terraform output -raw zone 2>/dev/null || echo "us-central1-a")

echo "════════════════════════════════════════════════════════════"
echo "  Generating network traffic before SCM onboarding"
echo "════════════════════════════════════════════════════════════"
echo "  Project: $PROJECT_ID"
echo "  Cluster: $CLUSTER"
echo "  Region:  $REGION"
echo ""
echo "  WHY THIS MATTERS:"
echo "  SCM detects the VPCs/subnets where the apps run based on"
echo "  traffic. The more traffic before onboarding, the better SCM"
echo "  visualizes the environment in the AIRS deployment wizard."
echo ""

# Pull kubeconfig
gcloud container clusters get-credentials "$CLUSTER" \
  --region "$REGION" \
  --project "$PROJECT_ID" 2>/dev/null || {
  echo "❌ Cannot pull kubeconfig. Verify the cluster exists."
  exit 1
}

# ─────────────────────────────────────────
# Step 1: Pod verification
# ─────────────────────────────────────────
echo "1️⃣  Checking app status..."

NI_PODS=$(kubectl get pods -n ai-chatbot --field-selector=status.phase=Running \
  -o name 2>/dev/null | wc -l | tr -d ' ')
API_PODS=$(kubectl get pods -n ai-api-chatbot --field-selector=status.phase=Running \
  -o name 2>/dev/null | wc -l | tr -d ' ')

echo "   Network Intercept chatbot pods: $NI_PODS running"
echo "   API Runtime chatbot pods:       $API_PODS running"

if [ "$NI_PODS" -eq 0 ] && [ "$API_PODS" -eq 0 ]; then
  echo ""
  echo "⚠️  No running pods! Run first: ./scripts/deploy-app.sh"
  echo "   Traffic will be generated only at the network level (DNS, GKE API)"
fi

# ─────────────────────────────────────────
# Step 2: Internal HTTP traffic (port-forward)
# ─────────────────────────────────────────
echo ""
echo "2️⃣  Generating HTTP traffic to apps..."

NI_POD=$(kubectl get pods -n ai-chatbot -o name 2>/dev/null | head -1)
API_POD=$(kubectl get pods -n ai-api-chatbot -o name 2>/dev/null | head -1)

if [ -n "$NI_POD" ]; then
  echo "   Traffic to Network Intercept chatbot..."
  kubectl port-forward -n ai-chatbot svc/ai-chatbot 18080:80 &>/dev/null &
  PF1_PID=$!
  sleep 3

  for i in {1..5}; do
    curl -s -X POST http://localhost:18080/api/chat \
      -H "Content-Type: application/json" \
      -d '{"message":"Hi, describe the GKE and Vertex AI architecture"}' \
      -o /dev/null 2>/dev/null && echo "   ✅ Request $i/5 to NI Chatbot" || true
    sleep 1
  done

  kill $PF1_PID 2>/dev/null || true
fi

if [ -n "$API_POD" ]; then
  echo "   Traffic to API Runtime chatbot..."
  kubectl port-forward -n ai-api-chatbot svc/api-chatbot 18081:80 &>/dev/null &
  PF2_PID=$!
  sleep 3

  for i in {1..5}; do
    curl -s http://localhost:18081/health -o /dev/null 2>/dev/null && \
      echo "   ✅ Request $i/5 to API Chatbot" || true
    curl -s http://localhost:18081/api/scan-status -o /dev/null 2>/dev/null || true
    sleep 1
  done

  kill $PF2_PID 2>/dev/null || true
fi

# ─────────────────────────────────────────
# Step 3: GKE → external network traffic
# (generates DNS and TCP traffic visible to AIRS)
# ─────────────────────────────────────────
echo ""
echo "3️⃣  Generating external traffic from GKE pods (DNS + HTTPS)..."

if [ -n "$NI_POD" ]; then
  # Traffic to GCP APIs (visible as Trust VPC → Internet)
  kubectl exec -n ai-chatbot $NI_POD -- sh -c \
    "for i in 1 2 3; do curl -s https://www.googleapis.com/discovery/v1/apis -o /dev/null && echo '  ✅ GCP API request' || true; sleep 2; done" \
    2>/dev/null || echo "   ⚠️  Skipped (pod unavailable)"
fi

# ─────────────────────────────────────────
# Step 4: DNS traffic (visibility in VPC flow logs)
# ─────────────────────────────────────────
echo ""
echo "4️⃣  Generating DNS queries..."

kubectl run dns-test --image=busybox:1.36 --restart=Never \
  -n default --rm -it --command -- sh -c \
  "for h in vertexai.googleapis.com aiplatform.googleapis.com storage.googleapis.com; do nslookup \$h; done" \
  2>/dev/null || echo "   ⚠️  DNS test skipped"

# ─────────────────────────────────────────
# Step 5: Activate VPC Flow Logs (if not enabled)
# ─────────────────────────────────────────
echo ""
echo "5️⃣  Checking VPC Flow Logs (required by SCM)..."

# Check ONLY our App subnet – SCM subnets (untrust, mgmt) don't exist
# until SCM-generated Terraform is applied (PHASE 5)
for SUBNET in airs-app-subnet; do
  STATUS=$(gcloud compute networks subnets describe "$SUBNET" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format="value(enableFlowLogs)" 2>/dev/null || echo "unknown")

  if [ "$STATUS" == "True" ]; then
    echo "   ✅ $SUBNET: Flow Logs enabled"
  else
    echo "   ⚠️  $SUBNET: Flow Logs disabled"
    echo "      Enabling..."
    gcloud compute networks subnets update "$SUBNET" \
      --enable-flow-logs \
      --region="$REGION" \
      --project="$PROJECT_ID" 2>/dev/null && \
      echo "   ✅ Flow Logs enabled for $SUBNET" || \
      echo "   ❌ Failed to enable (check permissions)"
  fi
done

# ─────────────────────────────────────────
# Summary
# ─────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Traffic generation complete!"
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Wait ~5 minutes for flow logs to propagate"
echo ""
echo "2. Onboard the GCP account in SCM:"
echo "   https://stratacloudmanager.paloaltonetworks.com"
echo "   → AI Security → AI Runtime → AI Runtime Firewall → Cloud Account Manager"
echo "   → Provide: Project ID, Bucket Name (from: terraform output scm_onboarding_bucket_name)"
echo ""
echo "3. Generate AIRS Terraform in SCM:"
echo "   → AI Runtime Security → Instances → Add Instance"
echo "   → Select GCP → pick the VPC where traffic is visible"
echo "   → Fill in network details from: terraform output scm_deployment_inputs"
echo "   → Download Terraform"
echo ""
echo "4. Apply SCM-generated Terraform:"
echo "   cd <directory-downloaded-from-scm>"
echo "   terraform init && terraform apply"
echo ""
echo "Network details to enter in the SCM wizard:"
terraform output scm_deployment_inputs 2>/dev/null || \
  echo "  Run: terraform output scm_deployment_inputs"
echo "════════════════════════════════════════════════════════════"
