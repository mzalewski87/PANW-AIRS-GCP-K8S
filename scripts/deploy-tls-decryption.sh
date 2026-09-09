#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  deploy-tls-decryption.sh – Upload AIRS Root CA into GKE
#
#  After configuring TLS Decryption in SCM (section 8.11 of the
#  DEPLOYMENT_GUIDE), export the Root CA from SCM (PEM) and run this script.
#
#  Script:
#  1. Creates a K8s Secret with the CA certificate in namespace ai-chatbot
#  2. Patches the ai-chatbot deployment — an initContainer APPENDS the AIRS CA
#     to the image's own trust store, and SSL env vars point at the result
#  3. Restarts pods and verifies
#
#  🔴 WHY AN initContainer AND NOT JUST SSL_CERT_FILE=<the CA>
#  Pointing SSL_CERT_FILE straight at the AIRS CA REPLACES the system trust
#  store instead of extending it. The pod then trusts the firewall and nothing
#  else — so it works only while decryption is actually happening. Run the
#  script one step too early (CNI not installed yet, bypass route still in
#  place, decryption rule not pushed) and ai-chatbot sees Google's real
#  certificate, fails verification and dies. Appending keeps the pod working in
#  BOTH states, which makes the deployment order forgiving instead of a trap.
#
#  The patch is a strategic merge patch keyed on resource names, so re-running
#  this script is idempotent — no duplicated volumes or env vars.
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
# Step 2: Patch deployment — bundle builder + SSL env vars
# ─────────────────────────────────────────
echo ""
echo "🔧 Patching deployment ai-chatbot (CA bundle builder + SSL env vars)..."

# The initContainer reuses the app's own image, so the bundle it builds is the
# exact trust store the app would otherwise have used — plus the AIRS CA.
APP_IMAGE=$(kubectl get deployment ai-chatbot -n ai-chatbot \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
if [ -z "$APP_IMAGE" ]; then
  echo "❌ Could not read the ai-chatbot image — is the deployment there?"
  exit 1
fi
echo "  Using image for the bundle builder: $APP_IMAGE"

kubectl patch deployment ai-chatbot -n ai-chatbot --type='strategic' -p="$(cat <<EOF
spec:
  template:
    spec:
      volumes:
        - name: airs-ca-cert
          secret:
            secretName: airs-ca-cert
            optional: true
        - name: airs-ca-bundle
          emptyDir: {}
      initContainers:
        - name: ca-bundle-builder
          image: $APP_IMAGE
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -e
              OUT=/bundle/ca-bundle.crt
              : > "\$OUT"
              # Debian trust store (used by OpenSSL / gRPC).
              [ -f /etc/ssl/certs/ca-certificates.crt ] && \\
                cat /etc/ssl/certs/ca-certificates.crt >> "\$OUT"
              # certifi bundle (used by requests) — belt and braces; duplicate
              # roots across both files are harmless to every consumer.
              python -c 'import certifi,sys; sys.stdout.write(open(certifi.where()).read())' \\
                >> "\$OUT" 2>/dev/null || true
              # …and finally the AIRS forward-trust CA.
              cat /ca/airs-ca.pem >> "\$OUT"
              echo "ca-bundle.crt built: \$(grep -c 'BEGIN CERTIFICATE' "\$OUT") certificates"
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: airs-ca-cert
              mountPath: /ca
              readOnly: true
            - name: airs-ca-bundle
              mountPath: /bundle
      containers:
        - name: ai-chatbot
          volumeMounts:
            - name: airs-ca-bundle
              mountPath: /etc/ssl/airs
              readOnly: true
          env:
            - name: SSL_CERT_FILE
              value: /etc/ssl/airs/ca-bundle.crt
            - name: REQUESTS_CA_BUNDLE
              value: /etc/ssl/airs/ca-bundle.crt
EOF
)"
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
echo "🔍 Verifying the CA bundle inside the pod..."
POD=$(kubectl get pods -n ai-chatbot -l app=ai-chatbot -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD" ]; then
  COUNT=$(kubectl exec -n ai-chatbot "$POD" -- \
    grep -c "BEGIN CERTIFICATE" /etc/ssl/airs/ca-bundle.crt 2>/dev/null || echo 0)
  # A bundle holding only the AIRS CA means the public roots were lost, which
  # breaks every request the firewall is NOT decrypting.
  if [ "$COUNT" -gt 1 ]; then
    echo "  ✅ ca-bundle.crt present in $POD — $COUNT certificates (public roots + AIRS CA)"
  elif [ "$COUNT" = "1" ]; then
    echo "  ⚠️  ca-bundle.crt holds only ONE certificate — the public roots are missing."
    echo "      Non-decrypted HTTPS will fail. Check the ca-bundle-builder logs:"
    echo "      kubectl logs -n ai-chatbot $POD -c ca-bundle-builder"
  else
    echo "  ⚠️  ca-bundle.crt not found — check the initContainer:"
    echo "      kubectl logs -n ai-chatbot $POD -c ca-bundle-builder"
  fi
else
  echo "  ⚠️  No ai-chatbot pod found"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ TLS Decryption configured for ai-chatbot!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "ai-chatbot pods now trust the AIRS Root CA as a TLS proxy, IN ADDITION to"
echo "the public roots — so they keep working whether or not the firewall is"
echo "currently decrypting. Order of deployment steps no longer matters here."
echo ""
echo "⚠️  api-chatbot was NOT changed — its traffic is not"
echo "   decrypted (it uses the AIRS SDK, not Network Intercept)."
echo ""
echo "Verification:"
echo "  1. Confirm the firewall is really the one terminating TLS — from a pod:"
echo "       kubectl exec -n ai-chatbot deploy/ai-chatbot -- \\"
echo "         python -c \"import ssl,socket;print(ssl.get_server_certificate(('${REGION:-us-central1}-aiplatform.googleapis.com',443)))\" \\"
echo "         | openssl x509 -noout -issuer"
echo "     The issuer must be the AIRS Root CA. Seeing a Google issuer means"
echo "     traffic is bypassing the firewall — check the routes and pan-cni."
echo "  2. Send a request to ai-chatbot"
echo "  3. SCM → Log Viewer → Firewall/Threat — decrypted AI traffic should appear"
echo ""
