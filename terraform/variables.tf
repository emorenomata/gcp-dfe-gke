variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "prj-emm-demos-2022"
}

variable "cluster_name" {
  description = "Nombre del clúster GKE"
  type        = string
  default     = "gke-dfe-test"
}

variable "region" {
  description = "Región del clúster GKE"
  type        = string
  default     = "us-central1"
}
