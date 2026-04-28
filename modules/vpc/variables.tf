variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "app_subnet_cidr" {
  description = "Application subnet CIDR (GKE nodes)"
  type        = string
}

variable "gke_pods_cidr" {
  description = "CIDR for GKE pods (secondary range)"
  type        = string
}

variable "gke_services_cidr" {
  description = "CIDR for GKE services (secondary range)"
  type        = string
}

variable "trust_subnet_cidr" {
  description = "Firewall trust subnet CIDR (SCM-managed). Added to the app VPC FW rule – without it, DNAT from the firewall to node:NodePort drops at the GCP level. Default = 10.1.2.0/24, matching the SCM-generated TF."
  type        = string
  default     = "10.1.2.0/24"
}

variable "labels" {
  description = "GCP labels"
  type        = map(string)
  default     = {}
}
