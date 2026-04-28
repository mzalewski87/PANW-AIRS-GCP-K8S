#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  patch-scm-terraform.sh – Patch SCM-generated Terraform
#
#  BEFORE PATCHING IT CHECKS: whether the mgmt interface HAS a public IP
#  (newer SCM templates have `create_public_ip = true` on mgmt).
#  If yes → SKIP PATCH (Cloud NAT is NOT required).
#
#  Patch is needed ONLY when mgmt is in a private subnet without a public IP:
#  - No Cloud NAT on mgmt VPC → firewall can't fetch its Device Cert (OCSP/CRL)
#  - Without the certificate it won't register with SCM
#
#  USAGE:
#    1. Unzip the SCM-generated Terraform
#    2. ./scripts/patch-scm-terraform.sh <path-to-security_project>
#    3. The script decides whether the patch is needed
#    4. If it generated the patch → terraform init && terraform apply
#
#  REQUIRED FQDNs and ports (if the patch is applied):
#    ocsp.paloaltonetworks.com          TCP 80
#    crl.paloaltonetworks.com           TCP 80
#    ocsp.godaddy.com                   TCP 80
#    api.paloaltonetworks.com           TCP 443
#    certificate.paloaltonetworks.com   TCP 443
#    *.gpcloudservice.com               TCP 443, 444
#
#  COMPATIBILITY: macOS BSD grep + GNU grep (POSIX regex, no -P).
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

# ─────────────────────────────────────────
# Parameters
# ─────────────────────────────────────────
SCM_DIR="${1:-}"

if [ -z "$SCM_DIR" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  patch-scm-terraform.sh – Patch SCM TF for AIRS bootstrap    ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Usage: $0 <path-to-security_project>"
  echo ""
  echo "Example:"
  echo "  tar -xzf scm-terraform.tar.gz"
  echo "  $0 ./extracted-folder/architecture/security_project"
  echo ""
  echo "The script checks whether the mgmt interface has a public IP:"
  echo "  - If YES (default in newer SCM templates) → SKIP patch"
  echo "  - If NO (mgmt private) → generates Cloud NAT + egress rules"
  exit 1
fi

if [ ! -d "$SCM_DIR" ]; then
  echo "❌ Directory does not exist: $SCM_DIR"
  exit 1
fi

TFVARS="$SCM_DIR/terraform.tfvars"
if [ ! -f "$TFVARS" ]; then
  echo "❌ Could not find $TFVARS"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Analysis of SCM-generated Terraform                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Directory: $SCM_DIR"
echo ""

# ─────────────────────────────────────────
# STEP 0: Check whether mgmt HAS a public IP
# ─────────────────────────────────────────
echo "🔍 Checking whether the mgmt interface has a public IP in terraform.tfvars..."

# Look for the network_interfaces block where subnetwork_key="fw-mgmt-sub"
# and check if create_public_ip = true.
# POSIX-friendly (no grep -P): use awk.
MGMT_HAS_PUBLIC_IP=$(awk '
  /network_interfaces[[:space:]]*=/ {in_ni=1}
  in_ni && /create_public_ip[[:space:]]*=[[:space:]]*true/ {has_public="yes"}
  in_ni && /subnetwork_key[[:space:]]*=[[:space:]]*"fw-mgmt/ {
    if (has_public == "yes") {print "yes"; exit}
    has_public=""
  }
  in_ni && /^\s*\}\s*\]/ {in_ni=0}
' "$TFVARS")

if [ "$MGMT_HAS_PUBLIC_IP" = "yes" ]; then
  echo "  ✅ mgmt interface HAS create_public_ip = true"
  echo ""
  echo "  Cloud NAT on mgmt VPC is NOT required – firewall has direct"
  echo "  internet access via external IP to PAN cert/SCM endpoints."
  echo ""
  echo "  PATCH NOT NEEDED – skip the script, continue with:"
  echo ""
  echo "    cd $SCM_DIR"
  echo "    terraform init"
  echo "    terraform plan"
  echo "    terraform apply"
  echo ""
  echo "  If you still want to force the patch (e.g. mgmt CIDR too restrictive),"
  echo "  run the script with FORCE=1: FORCE=1 $0 $SCM_DIR"
  echo ""
  if [ "${FORCE:-}" != "1" ]; then
    exit 0
  fi
  echo "  ⚠️  FORCE=1 – generating patch despite public IP on mgmt..."
  echo ""
fi

if [ "$MGMT_HAS_PUBLIC_IP" != "yes" ]; then
  echo "  ⚠️  mgmt interface has NO public IP – Cloud NAT IS required"
  echo ""
fi

# ─────────────────────────────────────────
# STEP 1: Detect mgmt VPC name (POSIX-friendly)
# ─────────────────────────────────────────
echo "🔍 Detecting mgmt VPC name..."

# In SCM template networks live in terraform.tfvars as a map.
# Look for the key containing "mgmt" inside the networks = { ... } section.
NAME_PREFIX=$(awk -F'"' '/^name_prefix[[:space:]]*=/ {print $2; exit}' "$TFVARS")
MGMT_VPC_KEY=$(awk '
  /^networks[[:space:]]*=/ {in_net=1; depth=0}
  in_net && /\{/ {depth++}
  in_net && /\}/ {depth--; if (depth==0) in_net=0}
  in_net && depth==1 && /^[[:space:]]*[a-zA-Z0-9_-]*mgmt[a-zA-Z0-9_-]*[[:space:]]*=/ {
    gsub(/^[[:space:]]+|[[:space:]]+=.*/,"")
    print
    exit
  }
' "$TFVARS")

# Actual VPC name in GCP = name_prefix + vpc_name (from inner vpc_name field)
MGMT_VPC_NAME=""
if [ -n "$MGMT_VPC_KEY" ]; then
  # Look for vpc_name = "..." inside the block of that key
  MGMT_VPC_INNER=$(awk -v key="$MGMT_VPC_KEY" '
    $0 ~ "^[[:space:]]*"key"[[:space:]]*=" {in_block=1}
    in_block && /vpc_name[[:space:]]*=/ {
      gsub(/.*vpc_name[[:space:]]*=[[:space:]]*"|".*/, "")
      print
      exit
    }
  ' "$TFVARS")
  MGMT_VPC_NAME="${NAME_PREFIX}${MGMT_VPC_INNER}"
fi

if [ -z "$MGMT_VPC_NAME" ]; then
  echo "  ⚠️  Could not auto-detect mgmt VPC name."
  echo "  Check terraform.tfvars – networks = { ... } section"
  read -p "  Enter mgmt VPC name in GCP (e.g. '<PREFIX>-fw-mgmt-vpc'): " MGMT_VPC_NAME
fi

echo "  ✅ Mgmt VPC in GCP: $MGMT_VPC_NAME"

# ─────────────────────────────────────────
# STEP 2: Project ID + region
# ─────────────────────────────────────────
SCM_PROJECT=$(awk -F'"' '/^project[[:space:]]*=/ {print $2; exit}' "$TFVARS")
SCM_REGION=$(awk -F'"' '/^region[[:space:]]*=/ {print $2; exit}' "$TFVARS")

echo "  Project: $SCM_PROJECT"
echo "  Region:  $SCM_REGION"
echo ""

# ─────────────────────────────────────────
# STEP 3: Check whether the patch already exists
# ─────────────────────────────────────────
PATCH_FILE="$SCM_DIR/airs_mgmt_nat_patch.tf"

if [ -f "$PATCH_FILE" ]; then
  echo "⚠️  Patch already exists: $PATCH_FILE"
  read -p "  Overwrite? (yes/no): " OVERWRITE
  [ "$OVERWRITE" != "yes" ] && { echo "  Skipped."; exit 0; }
fi

# ─────────────────────────────────────────
# STEP 4: Generate the patch (uses data sources, NOT TF resource references)
#
# Key point: the SCM template creates resources inside a MODULE
# (`module.firewall_common.module.vpc[...]`).
# Reference from the root won't work. Use `data "google_compute_network"`
# to look up the existing network by name.
# ─────────────────────────────────────────
echo "📝 Generating patch: $PATCH_FILE"

cat > "$PATCH_FILE" << PATCH_EOF
# ═══════════════════════════════════════════════════════════════════
#  PATCH: Cloud NAT + Egress Rules for the Management VPC
#
#  Generated by: scripts/patch-scm-terraform.sh
#  Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
#
#  Activated ONLY when the mgmt interface has NO public IP
#  (FORCE=1 or auto-detected create_public_ip = false).
#
#  Without this patch the VM-Series firewall cannot fetch its Device Certificate
#  and will not register with SCM.
#
#  Required FQDNs (egress allow-all on TCP 80/443/444 + DNS):
#    ocsp.paloaltonetworks.com, crl.paloaltonetworks.com   TCP 80
#    api.paloaltonetworks.com, certificate.paloaltonetworks.com  TCP 443
#    *.gpcloudservice.com                                  TCP 443, 444
# ═══════════════════════════════════════════════════════════════════

# Look up the existing mgmt VPC by name (created by the SCM module)
data "google_compute_network" "airs_mgmt_vpc_lookup" {
  name    = "${MGMT_VPC_NAME}"
  project = var.project_id

  # Wait until the SCM TF creates the network
  depends_on = [module.firewall_common]
}

# ─────────────────────────────────────────
# Cloud Router for the Management VPC
# ─────────────────────────────────────────
resource "google_compute_router" "airs_mgmt_router" {
  name    = "airs-mgmt-router"
  project = var.project_id
  region  = var.region
  network = data.google_compute_network.airs_mgmt_vpc_lookup.id
}

# ─────────────────────────────────────────
# Cloud NAT for the Management VPC
# ─────────────────────────────────────────
resource "google_compute_router_nat" "airs_mgmt_nat" {
  name                               = "airs-mgmt-nat"
  project                            = var.project_id
  router                             = google_compute_router.airs_mgmt_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ─────────────────────────────────────────
# Egress Firewall Rules – Management VPC
# ─────────────────────────────────────────
resource "google_compute_firewall" "airs_mgmt_egress_bootstrap" {
  name      = "airs-mgmt-allow-egress-bootstrap"
  project   = var.project_id
  network   = data.google_compute_network.airs_mgmt_vpc_lookup.name
  direction = "EGRESS"
  priority  = 900

  description = "Allow egress for AIRS FW bootstrap: OCSP, CRL, SCM API, device cert"

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "444"]
  }

  destination_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "airs_mgmt_egress_dns" {
  name      = "airs-mgmt-allow-egress-dns"
  project   = var.project_id
  network   = data.google_compute_network.airs_mgmt_vpc_lookup.name
  direction = "EGRESS"
  priority  = 900

  description = "Allow DNS egress for AIRS FW (resolution of OCSP/CRL/API FQDNs)"

  allow {
    protocol = "tcp"
    ports    = ["53"]
  }

  allow {
    protocol = "udp"
    ports    = ["53"]
  }

  destination_ranges = ["0.0.0.0/0"]
}
PATCH_EOF

echo "  ✅ Patch generated"
echo ""

# ─────────────────────────────────────────
# Step 5: Check there's no deny-all egress (POSIX-friendly)
# ─────────────────────────────────────────
echo "🔍 Checking existing egress deny rules..."

DENY_RULES=$(grep -rn "EGRESS" "$SCM_DIR"/*.tf 2>/dev/null | grep -i deny | grep -v '#' || true)

if [ -n "$DENY_RULES" ]; then
  echo "  ⚠️  Found deny egress rules in SCM TF:"
  echo "$DENY_RULES" | head -3
  echo "  Our patch has priority 900 – check that it doesn't collide."
else
  echo "  ✅ No explicit deny egress rules"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Patch ready! Now:"
echo ""
echo "  cd $SCM_DIR"
echo "  terraform init"
echo "  terraform plan    # Verify the patch compiles"
echo "  terraform apply"
echo ""
echo "After apply, monitor the serial console (wait 5-10 min):"
echo "  gcloud compute instances get-serial-port-output <vm-series-name> \\"
echo "    --zone=<zone> --project=$SCM_PROJECT | tail -200"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
