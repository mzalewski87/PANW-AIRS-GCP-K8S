# ═══════════════════════════════════════════════════════════════════
#  VPC Module – Application VPC (GKE + AI Apps)
#
#  This module creates ONLY the application network for GKE.
#  Firewall networks (mgmt, untrust, trust) are created by SCM-generated Terraform.
#  SCM peers its Trust VPC with our App VPC.
#
#  Architecture:
#    Our TF:   app-vpc (GKE)  ←── VPC Peering ──→  SCM: fw-trust-vpc
#    SCM TF:   fw-mgmt-vpc, fw-untrust-vpc, fw-trust-vpc (created by SCM)
# ═══════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────
# Application VPC (GKE, AI applications)
# SCM peers its Trust VPC with this network
# ─────────────────────────────────────────
resource "google_compute_network" "app" {
  name                    = "airs-app-vpc"
  auto_create_subnetworks = false
  project                 = var.project_id
  description             = "Application VPC – GKE cluster, AI chatbot apps. SCM peers its Trust VPC with this network via VPC Peering."
}

resource "google_compute_subnetwork" "app" {
  name          = "airs-app-subnet"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.app.id
  ip_cidr_range = var.app_subnet_cidr

  private_ip_google_access = true

  # Secondary ranges for GKE
  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = var.gke_pods_cidr
  }

  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = var.gke_services_cidr
  }

  # VPC Flow Logs – required for SCM discovery
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 1.0
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ─────────────────────────────────────────
# Cloud NAT – egress from App VPC (GKE → internet)
# Required for GKE nodes to pull images, access APIs
# ─────────────────────────────────────────
resource "google_compute_router" "app_router" {
  name    = "airs-app-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.app.id
}

resource "google_compute_router_nat" "app_nat" {
  name                               = "airs-app-nat"
  project                            = var.project_id
  router                             = google_compute_router.app_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ─────────────────────────────────────────
# Firewall Rules – App VPC (GKE)
# ─────────────────────────────────────────

# Internal traffic within App VPC (GKE nodes, pods, services)
resource "google_compute_firewall" "app_allow_internal" {
  name    = "airs-app-allow-internal"
  project = var.project_id
  network = google_compute_network.app.name

  description = "Internal traffic within App VPC (GKE nodes, pods, services) + firewall trust subnet (DNAT inbound)"

  allow {
    protocol = "all"
  }

  source_ranges = [
    var.app_subnet_cidr,
    var.gke_pods_cidr,
    var.gke_services_cidr,
    var.trust_subnet_cidr, # SCM-managed firewall trust subnet – DNAT inbound from untrust ELB to node:NodePort
  ]
}

# GKE master → nodes (required for cluster operation)
resource "google_compute_firewall" "app_allow_gke_master" {
  name    = "airs-app-allow-gke-master"
  project = var.project_id
  network = google_compute_network.app.name

  description = "GKE master → nodes (required)"

  allow {
    protocol = "tcp"
    ports    = ["443", "8443", "10250"]
  }

  source_ranges = ["172.16.0.0/28"] # GKE master CIDR
}

# GCP Health Checks (required for Load Balancers)
resource "google_compute_firewall" "app_allow_health_check" {
  name    = "airs-app-allow-health-check"
  project = var.project_id
  network = google_compute_network.app.name

  description = "GCP Health Checks for Load Balancers"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}
