# ═══════════════════════════════════════════════════════════════════
#  GKE Module – Kubernetes cluster for AI Chatbot applications
#  Deployed in the App VPC with Workload Identity and CNI readiness
#
#  NOTE: Kubernetes namespaces and ServiceAccounts are created by deploy-app.sh
#  (after gcloud container clusters get-credentials), NOT by Terraform.
#  Terraform creates only the GCP infrastructure (cluster + node pool).
# ═══════════════════════════════════════════════════════════════════

resource "google_container_cluster" "ai_cluster" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.region

  # We use a separate node pool – remove the default
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network
  subnetwork = var.subnetwork

  # 🔴 Pinned for PAN CNI compatibility – see variables.tf `kubernetes_version`.
  # GKE >= 1.35.1-gke.1516000 uses CNI spec 1.1.0, which pan-cni does not implement.
  min_master_version = var.kubernetes_version

  # VPC Native mode (alias IP) – required for the PAN CNI
  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Workload Identity – required for Vertex AI access
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Private cluster (master accessible from the trust network)
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "10.0.0.0/8"
      display_name = "internal-trusted"
    }
    # Allows management via bastion / cloud shell
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "all-admin-access"
    }
  }

  # Addons
  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    # Dataplane V2 (ADVANCED_DATAPATH) replaces Calico and provides
    # Network Policy enforcement via eBPF – do NOT enable network_policy_config
  }

  # NOTE: We do not use the network_policy { provider = "CALICO" } block
  # because datapath_provider = "ADVANCED_DATAPATH" (Dataplane V2)
  # provides Network Policy enforcement via eBPF and is mutually exclusive with Calico.

  # Logging and monitoring
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  # Dataplane V2 (eBPF) – required for PAN CNI Network Intercept on GKE
  datapath_provider = "ADVANCED_DATAPATH"

  # Allow terraform destroy without manual intervention
  deletion_protection = false

  # 🔴 UNSPECIFIED (no channel) by default. With a release channel GKE auto-upgrades
  # the control plane past 1.35.1-gke.1516000, which breaks PAN CNI (CNI spec 1.1.0)
  # and takes every node NotReady. Override via `release_channel` only if you are
  # NOT using Network Intercept / pan-cni.
  release_channel {
    channel = var.release_channel
  }

  resource_labels = var.labels

  # Maintenance window: daily 02:00-06:00 UTC (04:00-08:00 CET)
  # GKE requires a minimum of 48h of maintenance availability in every 32-day window
  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T02:00:00Z"
      end_time   = "2024-01-01T06:00:00Z"
      recurrence = "FREQ=DAILY"
    }
  }

  lifecycle {
    ignore_changes = [
      initial_node_count,
    ]
  }
}

# ─────────────────────────────────────────
# Node Pool – AI application nodes
# ─────────────────────────────────────────
resource "google_container_node_pool" "ai_nodes" {
  name     = "ai-app-pool"
  project  = var.project_id
  location = var.region
  cluster  = google_container_cluster.ai_cluster.name

  node_count = var.node_count

  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  # NOTE: node pool version is deliberately NOT pinned here. On create it inherits
  # the (pinned) master version, which is what we want. Setting it explicitly would
  # make `terraform apply` against an already-upgraded cluster attempt a node
  # DOWNGRADE, which GKE rejects – the apply would fail instead of no-op'ing.

  management {
    auto_repair = true
    # 🔴 Node auto-upgrade OFF – it would drift the nodes past the PAN CNI
    # version limit (CNI spec 1.1.0). Only valid with release_channel = UNSPECIFIED.
    auto_upgrade = var.release_channel == "UNSPECIFIED" ? false : true
  }

  node_config {
    machine_type    = var.machine_type
    service_account = var.gke_sa_email
    disk_size_gb    = 100
    disk_type       = "pd-ssd"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # Workload Identity per node
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Shielded VM
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # `airs-cni = enabled` is the node label the pan-cni DaemonSet is pinned to
    # (see kubernetes/cni/values-pan-cni.yaml → extraNodeSelector). Keeping the
    # selector in play even when every pool is CNI-capable means the same Helm
    # values work for a fresh deploy AND for the rescue pool you add when an
    # existing cluster has already auto-upgraded past the pan-cni version limit.
    labels = merge(var.labels, { airs-cni = "enabled" })

    tags = ["gke-node", "airs-trust"]

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
