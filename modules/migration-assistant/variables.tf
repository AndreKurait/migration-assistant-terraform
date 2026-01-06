variable "name" {
  description = "Name prefix for resources"
  type        = string
  default     = "migration-assistant"
}

variable "stage" {
  description = "Stage identifier (e.g., dev, prod)"
  type        = string
}

variable "eks_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.32"
}

# VPC Configuration
variable "create_vpc" {
  description = "Create new VPC or use existing"
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "Existing VPC ID (required if create_vpc = false)"
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Existing subnet IDs (required if create_vpc = false)"
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.212.0.0/16"
}

variable "azs" {
  description = "Availability zones"
  type        = list(string)
  default     = null
}

# EKS Configuration
variable "eks_public_access" {
  description = "Enable EKS public endpoint"
  type        = bool
  default     = true
}

variable "eks_node_pools" {
  description = "EKS Auto Mode node pools"
  type        = list(string)
  default     = ["general-purpose", "system"]
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
