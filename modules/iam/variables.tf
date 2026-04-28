variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "labels" {
  description = "GCP labels"
  type        = map(string)
  default     = {}
}
