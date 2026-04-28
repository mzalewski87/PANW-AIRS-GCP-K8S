#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  diagnose-airs.sh – Full diagnostics for AIRS Network Intercept
#
#  Checks all the key failure points:
#  1. VPC peering App ↔ Trust (state)
#  2. Routes 0.0.0.0/0 in App VPC (whether only the peering route wins)
#  3. Cloud NAT on mgmt VPC (only required when mgmt has no public IP)
#  4. Firewalls: status, license, Device Cert (via serial console)
#  5. ELB/ILB health checks (port, requestPath)
#  6. Backend services health (HEALTHY/UNHEALTHY)
#  7. GKE: namespace annotations, pan-cni daemonset, pod IPs, helm release
#  8. Connectivity test from a pod to Gemini API + AIRS API
#
#  Read-only – modifies nothing. Safe to run at any time.
#
#  USAGE: ./scripts/diagnose-airs.sh
# ═══════════════════════════════════════════════════════════════════

set -uo pipefail

# Helper – terraform output with fallback when warnings happen (no outputs returns a warning on stdout)
tf_out() {
  local val
  val=$(terraform output -raw "$1" 2>/dev/null || true)
  # Validation: empty or contains a warning marker '╷' / "Warning"
  if [ -z "$val" ] || [[ "$val" == *"╷"* ]] || [[ "$val" == *"Warning"* ]]; then
    return 1
  fi
  echo "$val"
}

PROJECT_ID=$(tf_out project_id 2>/dev/null || \
  grep '^project_id' terraform.tfvars 2>/dev/null | head -1 | awk -F'"' '{print $2}' || \
  gcloud config get-value project 2>/dev/null)
REGION=$(tf_out region 2>/dev/null || echo "us-central1")
APP_VPC="airs-app-vpc"
CLUSTER_NAME=$(tf_out gke_cluster_name 2>/dev/null || echo "airs-ai-cluster")

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  AIRS Network Intercept – Diagnostics                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Project: $PROJECT_ID"
echo "  Region:  $REGION"
echo "  App VPC: $APP_VPC"
echo ""

# ─────────────────────────────────────────
# Auto-detect SCM-generated resource prefix
# ─────────────────────────────────────────
SCM_PREFIX=$(gcloud compute networks list --project="$PROJECT_ID" \
  --filter="name~fw-trust-vpc" --format="value(name)" | head -1 | sed 's/-fw-trust-vpc//')

if [ -z "$SCM_PREFIX" ]; then
  echo "⚠️  Did not find fw-trust-vpc – AIRS not deployed or different naming"
  echo "   Skipping SCM-related tests"
fi

echo "  SCM prefix: ${SCM_PREFIX:-<not deployed>}"
echo ""

# ─────────────────────────────────────────
# 0. SCM API token (optional – if credentials are in .claude/secrets/)
# ─────────────────────────────────────────
# Pulls credentials from (in order):
#   1. Env vars: SCM_CLIENT_ID, SCM_CLIENT_SECRET, SCM_TSG_ID
#   2. ./secrets.env in PWD (preferred – see secrets.env.example)
#   3. <repo>/.claude/secrets/scm-api.json (Claude Code local)
#   4. ~/.claude-scm/scm-api.json (per-user fallback)
SCM_TOKEN=""
SCM_CLIENT_ID="${SCM_CLIENT_ID:-}"
SCM_CLIENT_SECRET="${SCM_CLIENT_SECRET:-}"
SCM_TSG_ID="${SCM_TSG_ID:-}"

# Source secrets.env if it exists (set -a so vars auto-export)
if [ -z "$SCM_CLIENT_ID" ] && [ -f "$PWD/secrets.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$PWD/secrets.env"
  set +a
fi

# Fallback: JSON files (Claude Code or per-user)
if [ -z "$SCM_CLIENT_ID" ]; then
  for SCM_SECRETS_FILE in \
      "$(dirname "$0")/../.claude/secrets/scm-api.json" \
      "$PWD/.claude/secrets/scm-api.json" \
      "$HOME/.claude-scm/scm-api.json"; do
    if [ -f "$SCM_SECRETS_FILE" ] && command -v python3 >/dev/null 2>&1; then
      SCM_CLIENT_ID=$(python3 -c "import json; print(json.load(open('$SCM_SECRETS_FILE'))['client_id'])" 2>/dev/null)
      SCM_CLIENT_SECRET=$(python3 -c "import json; print(json.load(open('$SCM_SECRETS_FILE'))['client_secret'])" 2>/dev/null)
      SCM_TSG_ID=$(python3 -c "import json; print(json.load(open('$SCM_SECRETS_FILE'))['tsg_id'])" 2>/dev/null)
      [ -n "$SCM_CLIENT_ID" ] && break
    fi
  done
fi

if [ -n "$SCM_CLIENT_ID" ] && [ -n "$SCM_CLIENT_SECRET" ] && [ -n "$SCM_TSG_ID" ]; then
  SCM_TOKEN=$(curl -s -d "grant_type=client_credentials&scope=tsg_id:$SCM_TSG_ID" \
    -u "$SCM_CLIENT_ID:$SCM_CLIENT_SECRET" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -X POST https://auth.apps.paloaltonetworks.com/oauth2/access_token 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
fi

# ─────────────────────────────────────────
# 1. VPC peering
# ─────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1️⃣  VPC Peering App ↔ Trust"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
gcloud compute networks peerings list --network="$APP_VPC" \
  --project="$PROJECT_ID" \
  --flatten="peerings[]" \
  --format="table(peerings.name:label=NAME,peerings.state:label=STATE,peerings.stateDetails:label=DETAILS)" 2>&1
echo ""

# ─────────────────────────────────────────
# 2. Routes 0.0.0.0/0 in App VPC – contextual analysis
#
# Mixed setup (CNI for some namespaces + bypass for others) IS VALID:
#  - bypass route (priority 500) → namespaces WITHOUT pan-fw annotation go directly
#  - peering route (priority 900) → namespaces WITH the annotation: pan-cni tunnels to ILB
#  - default route (priority 1000) → fallback
#
# pan-cni tunnel works INDEPENDENTLY of VPC routing (it encapsulates to a specific ILB IP).
# ─────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2️⃣  Routes 0.0.0.0/0 in App VPC"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
gcloud compute routes list --project="$PROJECT_ID" \
  --filter="network:$APP_VPC AND destRange=0.0.0.0/0" \
  --format="table(name,nextHopGateway.basename():label=GATEWAY,nextHopPeering:label=PEERING,priority)" \
  --sort-by=priority 2>&1

# Detect whether CNI is installed (decides whether mixed setup or single-firewall)
CNI_INSTALLED=""
if command -v helm >/dev/null 2>&1; then
  CNI_INSTALLED=$(helm list -A 2>/dev/null | grep -c ai-runtime-security || echo 0)
fi

HAS_BYPASS=$(gcloud compute routes list --project="$PROJECT_ID" \
  --filter="network:$APP_VPC AND name~bypass" --format="value(name)" 2>/dev/null | head -1)
HAS_PEERING=$(gcloud compute routes list --project="$PROJECT_ID" \
  --filter="network:$APP_VPC AND nextHopPeering:*" --format="value(name)" 2>/dev/null | head -1)

echo ""
if [ "$CNI_INSTALLED" -ge 1 ] && [ -n "$HAS_BYPASS" ] && [ -n "$HAS_PEERING" ]; then
  echo "  ✅ MIXED setup (CNI + bypass): correct for the dual-mode architecture"
  echo "     • Namespace with annotation 'paloaltonetworks.com/firewall=pan-fw' → pan-cni tunnel → firewall"
  echo "     • Namespace without annotation + bypass route → direct to internet (BYPASS)"
elif [ -n "$HAS_PEERING" ] && [ -z "$HAS_BYPASS" ]; then
  echo "  ✅ ALL-THROUGH-FIREWALL setup: all egress goes through the firewall (peering route only)"
elif [ -n "$HAS_BYPASS" ] && [ "$CNI_INSTALLED" -eq 0 ]; then
  echo "  ⚠️  Bypass route exists but CNI is NOT installed"
  echo "     → If this is a transient state (before Helm install) – OK"
  echo "     → If this is the target state: ./scripts/fix-routing.sh (removes bypass, all traffic via firewall)"
fi
echo ""

# ─────────────────────────────────────────
# 3. Cloud NAT on mgmt VPC
# ─────────────────────────────────────────
if [ -n "$SCM_PREFIX" ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "3️⃣  Cloud NAT / Public IP on mgmt VPC"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  FW_NAME=$(gcloud compute instances list --project="$PROJECT_ID" \
    --filter="name~${SCM_PREFIX}-fw-autoscale" --format="value(name)" | head -1)
  if [ -n "$FW_NAME" ]; then
    MGMT_IP=$(gcloud compute instances describe "$FW_NAME" \
      --zone="$(gcloud compute instances list --project="$PROJECT_ID" --filter="name=$FW_NAME" --format='value(zone.basename())')" \
      --project="$PROJECT_ID" \
      --format="value(networkInterfaces[1].accessConfigs[0].natIP)" 2>/dev/null)
    if [ -n "$MGMT_IP" ]; then
      echo "  ✅ Mgmt interface has public IP: $MGMT_IP – Cloud NAT NOT required"
    else
      echo "  ⚠️  Mgmt has no public IP – checking Cloud NAT on mgmt VPC..."
      gcloud compute routers list --project="$PROJECT_ID" \
        --filter="network:${SCM_PREFIX}-fw-mgmt-vpc" 2>&1
      echo "   → If empty: run ./scripts/patch-scm-terraform.sh before terraform apply"
    fi
  fi
  echo ""
fi

# ─────────────────────────────────────────
# 4. Firewalls: status, cert, SCM connection (via SCM API – authoritative)
# ─────────────────────────────────────────
if [ -n "$SCM_PREFIX" ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "4️⃣  VM-Series firewalls – status + Device Cert + SCM connection"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [ -n "$SCM_TOKEN" ]; then
    # SCM API – authoritative source
    echo "  Source: SCM API (authoritative)"
    curl -s "https://api.strata.paloaltonetworks.com/config/setup/v1/devices" \
      -H "Authorization: Bearer $SCM_TOKEN" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for d in data.get('data', []):
        host = d.get('hostname', '?')
        conn = '✅' if d.get('is_connected') else '❌'
        cert = '✅' if d.get('dev_cert_detail') == 'Valid' else '❌'
        push = '✅' if d.get('is_first_push_done') else '⚠️ '
        ver  = d.get('app_version', '?')
        sw   = d.get('software_version', '?')
        up   = d.get('uptime', '?')
        print(f'  • {host}')
        print(f'      Connected: {conn} | Cert: {cert} ({d.get(\"dev_cert_detail\",\"?\")}) | First Push: {push} | Content: {ver} | PAN-OS: {sw} | Uptime: {up}')
except Exception as e:
    print(f'  ⚠️  SCM API parse error: {e}')"
    echo ""
    echo "  Legend:"
    echo "    First Push ⚠️ = SCM 'is_first_push_done=False' flag – if Cert=✅ and Connected=✅,"
    echo "      and Push in the SCM UI returns OK, the flag is cosmetic and does NOT affect operation."
  else
    # Fallback: serial console (less reliable; SCM-bootstrap messages differ)
    echo "  Source: serial console (fallback – no SCM credentials in .claude/secrets/scm-api.json)"
    for FW in $(gcloud compute instances list --project="$PROJECT_ID" \
        --filter="name~${SCM_PREFIX}-fw-autoscale OR name~${SCM_PREFIX}-tc-vm" \
        --format="value(name)"); do
      ZONE=$(gcloud compute instances list --project="$PROJECT_ID" \
        --filter="name=$FW" --format='value(zone.basename())')
      STATUS=$(gcloud compute instances describe "$FW" --zone="$ZONE" \
        --project="$PROJECT_ID" --format="value(status)" 2>/dev/null)
      LOG=$(gcloud compute instances get-serial-port-output "$FW" \
        --zone="$ZONE" --project="$PROJECT_ID" 2>/dev/null)
      LICENSE=$(echo "$LOG" | grep -i "Successfully installed license" | tail -1)
      echo "  • $FW (zone $ZONE) – status: $STATUS"
      [ -n "$LICENSE" ] && echo "      ✅ license install in serial console" || echo "      ⚠️  no license install message"
      echo "      ℹ️  Full status (cert/SCM) needs the SCM API – add credentials to .claude/secrets/scm-api.json"
    done
  fi
  echo ""
fi

# ─────────────────────────────────────────
# 5. Health checks
# ─────────────────────────────────────────
if [ -n "$SCM_PREFIX" ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "5️⃣  Health checks ELB/ILB"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Expected:"
  echo "    ELB (HTTP):  port=80, path=/php/login.php  (PA-VM web GUI endpoint)"
  echo "    ILB (TCP):   port=443                       (PA-VM mgmt listens)"
  echo ""

  # Regional health checks
  for HC in $(gcloud compute health-checks list --project="$PROJECT_ID" \
      --filter="name~${SCM_PREFIX} AND region:$REGION" --format="value(name)" 2>/dev/null); do
    HCDATA=$(gcloud compute health-checks describe "$HC" --region="$REGION" \
      --project="$PROJECT_ID" --format="value(httpHealthCheck.port,httpHealthCheck.requestPath,tcpHealthCheck.port)" 2>/dev/null)
    PORT=$(echo "$HCDATA" | awk -F$'\t' '{print $1}')
    PATH_=$(echo "$HCDATA" | awk -F$'\t' '{print $2}')
    TCP=$(echo "$HCDATA" | awk -F$'\t' '{print $3}')

    STATUS="?"
    if [[ "$HC" == *"external-lb"* ]]; then
      if [ "$PORT" = "80" ] && [ "$PATH_" = "/php/login.php" ]; then
        STATUS="✅ OK"
      elif [ "$PORT" = "443" ]; then
        STATUS="❌ port 443 (HTTP won't work) – run ./scripts/fix-health-check.sh"
      else
        STATUS="⚠️  port=$PORT path=$PATH_ – check"
      fi
      echo "  • ELB $HC (HTTP) – $STATUS"
    elif [[ "$HC" == *"internal-lb"* ]]; then
      [ "$TCP" = "443" ] && STATUS="✅ OK (TCP/443)" || STATUS="⚠️  tcp_port=$TCP – check"
      echo "  • ILB $HC (TCP) – $STATUS"
    fi
  done

  # Global health checks (in some SCM templates the ILB is global)
  for HC in $(gcloud compute health-checks list --project="$PROJECT_ID" \
      --filter="name~${SCM_PREFIX} AND -region:*" --format="value(name)" 2>/dev/null); do
    HCDATA=$(gcloud compute health-checks describe "$HC" --global \
      --project="$PROJECT_ID" --format="value(tcpHealthCheck.port,httpHealthCheck.port,httpHealthCheck.requestPath)" 2>/dev/null)
    TCP=$(echo "$HCDATA" | awk -F$'\t' '{print $1}')
    if [ -n "$TCP" ] && [ "$TCP" != "" ]; then
      [ "$TCP" = "443" ] && STATUS="✅ OK (global TCP/443)" || STATUS="⚠️  tcp_port=$TCP"
      echo "  • $HC (TCP global) – $STATUS"
    fi
  done
  echo ""
fi

# ─────────────────────────────────────────
# 6. Backend health
# ─────────────────────────────────────────
if [ -n "$SCM_PREFIX" ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "6️⃣  Backend services health (HEALTHY/UNHEALTHY)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for BS in ${SCM_PREFIX}-external-lb ${SCM_PREFIX}-internal-lb; do
    echo ""
    echo "  • $BS"
    gcloud compute backend-services get-health "$BS" --region="$REGION" \
      --project="$PROJECT_ID" \
      --format="value(status.healthStatus[].instance.basename(),status.healthStatus[].healthState)" 2>/dev/null \
      | awk -F$'\t' '{print "    "$1" → "$2}'
  done
  echo ""
fi

# ─────────────────────────────────────────
# 7. GKE
# ─────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "7️⃣  GKE – CNI chaining state"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" --project="$PROJECT_ID" 2>/dev/null

echo ""
echo "  Namespace annotations:"
for NS in ai-chatbot ai-api-chatbot; do
  ANN=$(kubectl get namespace "$NS" -o json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('metadata', {}).get('annotations', {}).get('paloaltonetworks.com/firewall', ''))
except: pass" 2>/dev/null)
  if [ "$NS" = "ai-chatbot" ]; then
    [ "$ANN" = "pan-fw" ] && echo "    ✅ $NS → paloaltonetworks.com/firewall=pan-fw (CNI inspection on)" \
                          || echo "    ❌ $NS → MISSING annotation (should be pan-fw – traffic does not go via firewall)"
  else
    [ -z "$ANN" ] && echo "    ✅ $NS → no annotation (expected – API Intercept SDK protects on its own)" \
                  || echo "    ⚠️  $NS → annotation '$ANN' (should NOT be there – API Intercept)"
  fi
done

echo ""
echo "  pan-cni daemonset (Helm release):"
HELM_FOUND=$(helm list -A 2>/dev/null | grep ai-runtime-security | head -1)
if [ -n "$HELM_FOUND" ]; then
  echo "    ✅ $(echo "$HELM_FOUND" | awk '{print "release="$1, "ns="$2, "rev="$3, "status="$8}')"
  kubectl get daemonset -n kube-system 2>/dev/null | grep -i pan-cni | awk '{print "    ✅ "$1": "$4"/"$3" ready"}'
else
  echo "    ❌ Helm release ai-runtime-security NOT installed"
  echo "       → Download the Helm chart from the SCM template (architecture/helm) and install"
fi

echo ""
echo "  pan-cni endpoint slice (should point to the ILB IP):"
ES=$(kubectl get endpointslice -n kube-system 2>/dev/null | grep -i pan)
if [ -n "$ES" ]; then
  echo "$ES" | awk '{print "    ✅ "$1": ports="$3" endpoints="$4}'
else
  echo "    ❌ No pan endpointslice – CNI not registered"
fi

echo ""
echo "  Pod IPs in ai-chatbot (should be from Pod CIDR 10.100.x.x):"
kubectl get pods -n ai-chatbot -o jsonpath='{range .items[*]}    {.metadata.name}{": "}{.status.podIP}{"\n"}{end}' 2>/dev/null

echo ""

# ─────────────────────────────────────────
# 8. Pod status per namespace (deployment health)
# ─────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "8️⃣  Pod status (deployment health)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for NS in ai-chatbot ai-api-chatbot; do
  PODS_DATA=$(kubectl get pods -n "$NS" -o json 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for p in data.get('items', []):
        name = p['metadata']['name']
        phase = p['status'].get('phase', '?')
        cs = p['status'].get('containerStatuses', [{}])[0]
        ready = '✅' if cs.get('ready') else '❌'
        restarts = cs.get('restartCount', 0)
        ip = p['status'].get('podIP', '?')
        warn = ''
        if restarts > 2:
            warn = f' ⚠️  RESTART LOOP ({restarts}×)'
        elif not cs.get('ready') and phase == 'Running':
            warn = ' ⚠️  Running but NOT READY (probe failures?)'
        print(f'    {ready} {name:40} phase={phase:10} ready={cs.get(\"ready\")} restarts={restarts} ip={ip}{warn}')
except Exception as e:
    print(f'    error: {e}')" 2>/dev/null)

  if [ -n "$PODS_DATA" ]; then
    echo "  • Namespace: $NS"
    echo "$PODS_DATA"
  else
    echo "  • Namespace: $NS – no pods (or namespace doesn't exist)"
  fi
  echo ""
done

# ─────────────────────────────────────────
# 9. Connectivity test from a READY ai-chatbot pod
# ─────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "9️⃣  Connectivity test from a READY ai-chatbot pod"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# Pick a pod with containerStatuses[0].ready = true
POD=$(kubectl get pods -n ai-chatbot -l app=ai-chatbot -o json 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for p in data.get('items', []):
        if p.get('status', {}).get('containerStatuses', [{}])[0].get('ready'):
            print(p['metadata']['name'])
            break
except: pass" 2>/dev/null)

if [ -n "$POD" ]; then
  echo "  Pod: $POD (Ready)"
  for HOST in generativelanguage.googleapis.com service.api.aisecurity.paloaltonetworks.com; do
    RESULT=$(kubectl exec -n ai-chatbot "$POD" -- timeout 5 curl -sko /dev/null -w "%{http_code}/%{time_total}s" -I "https://$HOST" 2>/dev/null || echo "TIMEOUT")
    echo "    $HOST → $RESULT"
  done
else
  echo "  ⚠️  No Ready ai-chatbot pod – none are ready (check section 8)"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Diagnostics complete                                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Most common issues:"
echo "  • Backend LB UNHEALTHY → ./scripts/fix-health-check.sh"
echo "  • Pods ⚠️  RESTART LOOP after CNI annotation → debug pan-cni tunnel"
echo "    (most likely the liveness probe HTTP doesn't return through the tunnel)"
echo "  • Missing Device Cert (section 4) → check the PIN in CSP, recreate the firewall"
echo "  • Full troubleshooting → docs/TROUBLESHOOTING.md"
