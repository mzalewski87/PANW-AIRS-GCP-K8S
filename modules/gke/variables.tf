variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
}

variable "network" {
  description = "Trust VPC self-link"
  type        = string
}

variable "subnetwork" {
  description = "Trust subnet self-link"
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for pods"
  type        = string
}

variable "services_range_name" {
  description = "Secondary range name for services"
  type        = string
}

variable "node_count" {
  description = "Number of GKE nodes"
  type        = number
  default     = 2
}

# ─────────────────────────────────────────
# 🔴 CNI compatibility pin
#
# GKE Dataplane V2 on 1.35.1-gke.1516000+ writes "cniVersion": "1.1.0" into the
# node CNI conflist; containerd 2.x then issues the CNI STATUS verb. PAN's
# pan-cni image (all published tags: 4.0.0 / 4.0.1 / 4.0.2) advertises CNI
# 0.4.0 at most and answers `unknown CNI_COMMAND: STATUS`, which takes EVERY
# node NotReady (NetworkPluginNotReady) as soon as the DaemonSet rolls out.
#
# PANW documents "Kubernetes 1.30 and above with CNI specification 0.4.0+", so
# we pin below the threshold. Bump this once PANW ships a pan-cni that
# implements STATUS (CNI spec 1.1.0).
#
# ⚠️ THIS PIN ONLY TAKES EFFECT ON CLUSTER CREATE.
# `min_master_version` is a floor, not a target: GKE never downgrades a control
# plane, so applying this to an existing 1.35+ cluster changes nothing. An
# already-upgraded cluster must be RECREATED to run pan-cni.
# ─────────────────────────────────────────
variable "kubernetes_version" {
  description = "GKE master version, applied at CREATE time only. Must stay below 1.35.1-gke.1516000 for PAN CNI (CNI spec 1.1.0 incompatibility). Existing clusters above it must be recreated."
  type        = string
  default     = "1.34"
}

variable "release_channel" {
  description = "GKE release channel. Use UNSPECIFIED when pinning kubernetes_version, otherwise GKE auto-upgrades past the PAN CNI limit."
  type        = string
  default     = "UNSPECIFIED"
}

variable "machine_type" {
  description = "Node machine type"
  type        = string
  default     = "e2-standard-4"
}

variable "min_node_count" {
  description = "Min nodes (autoscaling)"
  type        = number
  default     = 1
}

variable "max_node_count" {
  description = "Max nodes (autoscaling)"
  type        = number
  default     = 4
}

variable "gke_sa_email" {
  description = "GKE node Service Account email"
  type        = string
}

# ai_app_sa_email removed – namespaces and KSA are created by deploy-app.sh, not Terraform

variable "labels" {
  description = "GCP labels"
  type        = map(string)
  default     = {}
}
