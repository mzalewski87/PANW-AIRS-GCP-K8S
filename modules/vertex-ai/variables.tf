variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "endpoint_name" {
  description = "Vertex AI endpoint name"
  type        = string
}

variable "model_id" {
  description = "Vertex AI model ID (Gemini)"
  type        = string
  default     = "gemini-2.5-flash"
}

variable "gke_sa_email" {
  description = "GKE Service Account email (Vertex AI access)"
  type        = string
}

variable "trust_network_id" {
  description = "Trust VPC network ID (for PSC)"
  type        = string
  default     = ""
}

variable "labels" {
  description = "GCP labels"
  type        = map(string)
  default     = {}
}
