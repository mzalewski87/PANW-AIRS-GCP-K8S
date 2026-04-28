#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  switch-language.sh – Bidirectional UI language switcher for both
#                       AIRS demo chatbots running on GKE.
#
#  WHAT IT DOES:
#  Sets the APP_LANG env var on the ai-chatbot and api-chatbot
#  Deployments, then rolls a restart of both. Translation files
#  (i18n/<lang>.json) are baked into the container images, so no
#  rebuild is required – just an env-var flip + rolling restart.
#
#  USAGE:
#    ./scripts/switch-language.sh en      # English (default)
#    ./scripts/switch-language.sh pl      # Polish
#    ./scripts/switch-language.sh de      # any code with i18n/de.json
#    ./scripts/switch-language.sh         # show current state
#
#  TO ADD A NEW LANGUAGE:
#    1. cp kubernetes/app/i18n/en.json        kubernetes/app/i18n/<code>.json
#    2. cp kubernetes/api-chatbot/i18n/en.json kubernetes/api-chatbot/i18n/<code>.json
#    3. Translate every value (keys MUST stay identical)
#    4. Rebuild + push images: ./scripts/deploy-app.sh
#    5. ./scripts/switch-language.sh <code>
#
#  REQUIREMENTS:
#  - kubectl context pointing at the GKE cluster
#  - Both chatbots already deployed (deploy-app.sh executed)
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

# ─────────────────────────────────────────
# Constants
# ─────────────────────────────────────────
APP_NS="ai-chatbot"
APP_DEPLOY="ai-chatbot"
API_NS="ai-api-chatbot"
API_DEPLOY="api-chatbot"
ENV_VAR="APP_LANG"
ROLLOUT_TIMEOUT="180s"

# ─────────────────────────────────────────
# Colours (only when stdout is a TTY)
# ─────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

# ─────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────
die() { echo "${C_RED}❌ $*${C_RESET}" >&2; exit 1; }
info() { echo "${C_BLUE}ℹ️  $*${C_RESET}"; }
ok()   { echo "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo "${C_YELLOW}⚠️  $*${C_RESET}"; }

current_lang() {
  local ns="$1" deploy="$2"
  kubectl -n "$ns" get deployment "$deploy" \
    -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='$ENV_VAR')].value}" \
    2>/dev/null || echo ""
}

list_available_langs() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    find "$dir" -maxdepth 1 -name '*.json' -type f -print0 \
      | xargs -0 -n1 basename \
      | sed 's/\.json$//' \
      | sort
  fi
}

# ─────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────
command -v kubectl >/dev/null 2>&1 || die "kubectl is not installed"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_I18N_DIR="$REPO_ROOT/kubernetes/app/i18n"
API_I18N_DIR="$REPO_ROOT/kubernetes/api-chatbot/i18n"

# ─────────────────────────────────────────
# No argument → status
# ─────────────────────────────────────────
TARGET_LANG="${1:-}"

if [[ -z "$TARGET_LANG" ]]; then
  echo ""
  echo "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
  echo "${C_BOLD}║   AIRS Demo Chatbots – Current UI language                  ║${C_RESET}"
  echo "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
  echo ""
  if kubectl -n "$APP_NS" get deployment "$APP_DEPLOY" >/dev/null 2>&1; then
    cur="$(current_lang "$APP_NS" "$APP_DEPLOY")"
    echo "  ai-chatbot (Network Intercept):    ${C_BOLD}${cur:-<unset, default 'en'>}${C_RESET}"
  else
    echo "  ai-chatbot (Network Intercept):    ${C_YELLOW}deployment not found${C_RESET}"
  fi
  if kubectl -n "$API_NS" get deployment "$API_DEPLOY" >/dev/null 2>&1; then
    cur="$(current_lang "$API_NS" "$API_DEPLOY")"
    echo "  api-chatbot (API Runtime):         ${C_BOLD}${cur:-<unset, default 'en'>}${C_RESET}"
  else
    echo "  api-chatbot (API Runtime):         ${C_YELLOW}deployment not found${C_RESET}"
  fi
  echo ""
  echo "  Available translation files:"
  echo "    ai-chatbot/i18n/   : $(list_available_langs "$APP_I18N_DIR" | tr '\n' ' ')"
  echo "    api-chatbot/i18n/  : $(list_available_langs "$API_I18N_DIR" | tr '\n' ' ')"
  echo ""
  echo "  Switch with:  $0 <lang>     (e.g. en, pl)"
  echo ""
  exit 0
fi

TARGET_LANG="$(echo "$TARGET_LANG" | tr '[:upper:]' '[:lower:]')"

# ─────────────────────────────────────────
# Validate translation files
# ─────────────────────────────────────────
APP_TRANSLATION="$APP_I18N_DIR/$TARGET_LANG.json"
API_TRANSLATION="$API_I18N_DIR/$TARGET_LANG.json"

if [[ ! -f "$APP_TRANSLATION" ]]; then
  warn "Translation file missing locally: $APP_TRANSLATION"
  warn "The app will fall back to English at runtime if the file is also missing in the image."
fi
if [[ ! -f "$API_TRANSLATION" ]]; then
  warn "Translation file missing locally: $API_TRANSLATION"
  warn "The app will fall back to English at runtime if the file is also missing in the image."
fi

# ─────────────────────────────────────────
# Confirm + apply
# ─────────────────────────────────────────
echo ""
info "Switching UI language to: ${C_BOLD}$TARGET_LANG${C_RESET}"
echo ""

# Track which deployments we touched, for the rollout-status pass.
TOUCHED_DEPLOYMENTS=()

switch_one() {
  local ns="$1" deploy="$2"
  if ! kubectl -n "$ns" get deployment "$deploy" >/dev/null 2>&1; then
    warn "Skipping $ns/$deploy – deployment not found"
    return
  fi
  local cur
  cur="$(current_lang "$ns" "$deploy")"
  if [[ "$cur" == "$TARGET_LANG" ]]; then
    ok "$ns/$deploy already set to '$TARGET_LANG' – no change"
    return
  fi
  info "Setting $ENV_VAR=$TARGET_LANG on $ns/$deploy (was: '${cur:-<unset>}')"
  kubectl -n "$ns" set env "deployment/$deploy" "$ENV_VAR=$TARGET_LANG" >/dev/null
  kubectl -n "$ns" rollout restart "deployment/$deploy" >/dev/null
  TOUCHED_DEPLOYMENTS+=("$ns|$deploy")
  ok "Triggered rollout for $ns/$deploy"
}

switch_one "$APP_NS" "$APP_DEPLOY"
switch_one "$API_NS" "$API_DEPLOY"

if [[ ${#TOUCHED_DEPLOYMENTS[@]} -eq 0 ]]; then
  echo ""
  ok "Nothing to do – both deployments already use APP_LANG=$TARGET_LANG."
  exit 0
fi

# ─────────────────────────────────────────
# Wait for rollouts
# ─────────────────────────────────────────
echo ""
info "Waiting for rollouts to finish (timeout: $ROLLOUT_TIMEOUT)..."
for entry in "${TOUCHED_DEPLOYMENTS[@]}"; do
  ns="${entry%%|*}"
  deploy="${entry##*|}"
  if kubectl -n "$ns" rollout status "deployment/$deploy" --timeout="$ROLLOUT_TIMEOUT"; then
    ok "$ns/$deploy is ready"
  else
    die "Rollout for $ns/$deploy did not complete within $ROLLOUT_TIMEOUT"
  fi
done

# ─────────────────────────────────────────
# Final summary
# ─────────────────────────────────────────
echo ""
echo "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
echo "${C_BOLD}║   Language switch complete – summary                        ║${C_RESET}"
echo "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
echo ""
echo "  ai-chatbot  (Network Intercept):  $(current_lang "$APP_NS" "$APP_DEPLOY")"
echo "  api-chatbot (API Runtime):        $(current_lang "$API_NS" "$API_DEPLOY")"
echo ""
ok "Refresh the chatbot pages in your browser to see the new language."
echo ""
