variable "project_id" {
  description = "The Google Cloud project ID where resources will be deployed."
  type        = string
}

variable "default_region" {
  description = "Default provider region (not used for subnet creation, which specifies regions explicitly)."
  type        = string
  default     = "us-central1"
}

variable "vpc_name" {
  description = "Name of the shared VPC network."
  type        = string
  default     = "vpc-global"
}

# ── Subnet regions ────────────────────────────────────────────────────────────

variable "central_region" {
  description = "Region for the central subnet."
  type        = string
  default     = "us-central1"
}

variable "west_region" {
  description = "Region for the west subnet."
  type        = string
  default     = "us-west1"
}

variable "east_region" {
  description = "Region for the east subnet."
  type        = string
  default     = "us-east1"
}

# ── Primary node CIDR ranges (/20) ───────────────────────────────────────────

variable "central_subnet_cidr" {
  description = "Primary CIDR range for the central subnet (node addresses)."
  type        = string
  default     = "10.0.0.0/20"
}

variable "west_subnet_cidr" {
  description = "Primary CIDR range for the west subnet (node addresses)."
  type        = string
  default     = "10.1.0.0/20"
}

variable "east_subnet_cidr" {
  description = "Primary CIDR range for the east subnet (node addresses)."
  type        = string
  default     = "10.2.0.0/20"
}

# ── GKE Pod secondary ranges (/14) ───────────────────────────────────────────

variable "central_pods_cidr" {
  description = "Secondary CIDR range for GKE pods in the central subnet."
  type        = string
  default     = "10.4.0.0/14"
}

variable "west_pods_cidr" {
  description = "Secondary CIDR range for GKE pods in the west subnet."
  type        = string
  default     = "10.8.0.0/14"
}

variable "east_pods_cidr" {
  description = "Secondary CIDR range for GKE pods in the east subnet."
  type        = string
  default     = "10.12.0.0/14"
}

# ── GKE Services secondary ranges (/20) ──────────────────────────────────────

variable "central_services_cidr" {
  description = "Secondary CIDR range for GKE services in the central subnet."
  type        = string
  default     = "10.16.0.0/20"
}

variable "west_services_cidr" {
  description = "Secondary CIDR range for GKE services in the west subnet."
  type        = string
  default     = "10.17.0.0/20"
}

variable "east_services_cidr" {
  description = "Secondary CIDR range for GKE services in the east subnet."
  type        = string
  default     = "10.18.0.0/20"
}
