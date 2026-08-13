#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  patch-pan-cni-chart.sh – make the SCM pan-cni chart node-selectable
#
#  🔴 WHY THIS EXISTS
#  The official PANW `ai-runtime-security` chart shipped inside the SCM
#  Terraform bundle hardcodes the DaemonSet's nodeSelector:
#
#      nodeSelector:
#        beta.kubernetes.io/os: linux
#
#  so pan-cni lands on EVERY Linux node in the cluster with no way to opt out.
#  That is a problem, because pan-cni 4.0.2 advertises CNI spec <= 0.4.0 while
#  GKE >= 1.35.1-gke.1516000 writes `"cniVersion": "1.1.0"` into the node
#  conflist. containerd 2.x then issues the CNI STATUS verb, pan-cni answers
#  `unknown CNI_COMMAND: STATUS`, and the node goes NotReady with
#  NetworkPluginNotReady. On a mixed cluster the DaemonSet would take down
#  nodes that are not running Network Intercept at all.
#
#  This script adds ONE templated block so `extraNodeSelector` in
#  kubernetes/cni/values-pan-cni.yaml is honoured. With that key absent the
#  rendered output is byte-identical to upstream, so the patch is a no-op for
#  anyone not using it.
#
#  Idempotent: re-running on an already-patched chart is a no-op.
#
#  Usage:
#    ./scripts/patch-pan-cni-chart.sh <unzipped-scm-bundle>/architecture/helm
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

CHART_DIR="${1:-}"

if [ -z "$CHART_DIR" ]; then
  echo "❌ Usage: $0 <scm-bundle>/architecture/helm"
  echo "   The chart directory is the one containing Chart.yaml and templates/."
  exit 1
fi

DS="$CHART_DIR/templates/pan-cni.yaml"

if [ ! -f "$DS" ]; then
  echo "❌ Not a pan-cni chart directory: $DS not found."
  echo "   Note: in recent SCM bundles the chart sits directly in"
  echo "   architecture/helm/, NOT architecture/helm/ai-runtime-security/."
  exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " 🔧 Patching pan-cni chart for node selection"
echo "═══════════════════════════════════════════════════════════════════"
echo " Chart: $CHART_DIR"
echo ""

# ─────────────────────────────────────────
# Already patched?
# ─────────────────────────────────────────
if grep -q "extraNodeSelector" "$DS"; then
  echo " ✅ Already patched – nothing to do."
  echo ""
  exit 0
fi

if ! grep -q "beta.kubernetes.io/os: linux" "$DS"; then
  echo " ❌ Could not find the expected nodeSelector anchor in:"
  echo "    $DS"
  echo "    The chart layout has changed – patch it by hand:"
  echo "    add the {{- range \$k, \$v := .Values.extraNodeSelector }} block"
  echo "    under spec.template.spec.nodeSelector."
  exit 1
fi

cp "$DS" "$DS.orig"
echo " 📦 Backup: $DS.orig"

# ─────────────────────────────────────────
# Insert the range block right after the hardcoded selector entry.
# BSD sed (macOS) and GNU sed disagree on -i, so write to a temp file.
# ─────────────────────────────────────────
awk '
  { print }
  /beta\.kubernetes\.io\/os: linux/ && !done {
    print "{{- range $k, $v := .Values.extraNodeSelector }}"
    print "        {{ $k }}: {{ $v | quote }}"
    print "{{- end }}"
    done = 1
  }
' "$DS.orig" > "$DS"

echo " ✅ Added extraNodeSelector support to the DaemonSet template"
echo ""
echo " Verify the render before installing:"
echo "   helm template ai-runtime-security $CHART_DIR \\"
echo "     -f kubernetes/cni/values-pan-cni.yaml | grep -A4 nodeSelector"
echo ""
echo " Expected:"
echo "   nodeSelector:"
echo "     beta.kubernetes.io/os: linux"
echo "     airs-cni: \"enabled\""
echo ""
