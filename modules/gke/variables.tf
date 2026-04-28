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
