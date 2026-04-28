#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  deploy-tls-decryption.sh – Upload AIRS Root CA into GKE
#
#  After configuring TLS Decryption in SCM (section 8.11 of the
#  DEPLOYMENT_GUIDE), export the Root CA from SCM (PEM) and run this script.
#
#  Script:
#  1. Creates a K8s Secret with the CA certificate in namespace ai-chatbot
#  2. Patches the ai-chatbot deployment — adds volume mount + SSL env vars
#  3. Restarts pods and verifies
#
#  NOTE: This script patches ONLY ai-chatbot (Network Intercept).
#  api-chatbot (API Runtime Intercept) does NOT need TLS decryption —
#  its traffic to the AIRS SCP API should not be decrypted.
#
#  USAGE:
#    ./scripts/deploy-tls-decryption.sh <path-to-root-ca.pem>
#
#  PREREQUISITES:
#    - kubectl configured (gcloud container clusters get-credentials)
#    - Namespace ai-chatbot must exist
#    - Root CA exported from SCM (Objects → Certificate Management)
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

CA_FILE="${1:-}"

if [ -z "$CA_FILE" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  deploy-tls-decryption.sh – Upload AIRS Root CA to GKE       ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Usage: $0 <path-to-root-ca.pem>"
  echo ""
  echo "How to get the Root CA:"
  echo "  1. SCM → Objects → Certificate Management"
  echo "  2. Pick the Root CA → Export Certificate"
  echo "  3. Format: Base64 Encoded Certificate (PEM)"
  echo "  4. Save the file and pass the path to this script"
  echo ""
  exit 1
fi

if [ ! -f "$CA_FILE" ]; then
  echo "❌ File does not exist: $CA_FILE"
  exit 1
fi

# Validation: check that this is a PEM
if ! grep -q "BEGIN CERTIFICATE" "$CA_FILE"; then
  echo "❌ File doesn't look like a PEM certificate: $CA_FILE"
  echo "   Expected format: -----BEGIN CERTIFICATE-----"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Uploading AIRS Root CA to GKE (ai-chatbot only)             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  CA File: $CA_FILE"
echo ""

# ─────────────────────────────────────────
# Step 1: Create Secret in namespace ai-chatbot
# ─────────────────────────────────────────
echo "📜 Creating Secret airs-ca-cert in namespace ai-chatbot..."
kubectl create secret generic airs-ca-cert \
  --from-file=airs-ca.pem="$CA_FILE" \
  -n ai-chatbot \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  ✅ Secret created in ai-chatbot"

# ─────────────────────────────────────────
# Step 2: Patch deployment — add volume, volumeMount and env vars
# ─────────────────────────────────────────
echo ""
echo "🔧 Patching deployment ai-chatbot (CA cert mount + SSL env vars)..."

kubectl patch deployment ai-chatbot -n ai-chatbot --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "airs-ca-cert",
      "secret": {
        "secretName": "airs-ca-cert",
        "optional": true
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "airs-ca-cert",
      "mountPath": "/etc/ssl/certs/airs-ca.pem",
      "subPath": "airs-ca.pem",
      "readOnly": true
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "SSL_CERT_FILE",
      "value": "/etc/ssl/certs/airs-ca.pem"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "REQUESTS_CA_BUNDLE",
      "value": "/etc/ssl/certs/airs-ca.pem"
    }
  }
]'
echo "  ✅ Deployment ai-chatbot patched"

# ─────────────────────────────────────────
# Step 3: Wait for readiness
# ─────────────────────────────────────────
echo ""
echo "⏳ Waiting for ai-chatbot pods to be ready..."

kubectl rollout status deployment/ai-chatbot -n ai-chatbot --timeout=120s 2>/dev/null || \
  echo "  ⚠️  Timeout — check manually: kubectl get pods -n ai-chatbot"

# ─────────────────────────────────────────
# Step 4: Verification
# ─────────────────────────────────────────
echo ""
echo "🔍 Verifying CA cert mount..."
POD=$(kubectl get pods -n ai-chatbot -l app=ai-chatbot -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD" ]; then
  if kubectl exec -n ai-chatbot "$POD" -- cat /etc/ssl/certs/airs-ca.pem > /dev/null 2>&1; then
    echo "  ✅ CA cert correctly mounted in pod $POD"
  else
    echo "  ⚠️  CA cert not found in the pod — check the mount"
  fi
else
  echo "  ⚠️  No ai-chatbot pod found"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ TLS Decryption configured for ai-chatbot!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "ai-chatbot pods now trust the AIRS Root CA as a TLS proxy."
echo "HTTPS traffic to the Gemini API will be decrypted by the firewall."
echo ""
echo "⚠️  api-chatbot was NOT changed — its traffic is not"
echo "   decrypted (it uses the AIRS SDK, not Network Intercept)."
echo ""
echo "Verification:"
echo "  1. Send a request to ai-chatbot"
echo "  2. SCM → Log Viewer → Firewall/Threat"
echo "  3. You should see logs from the decrypted AI traffic"
echo ""
