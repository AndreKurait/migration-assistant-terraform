terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  default = "us-east-2"
}

variable "stage" {
  default = "dev"
}

module "migration_assistant" {
  source = "../../modules/migration-assistant"

  stage       = var.stage
  create_vpc  = true
  eks_version = "1.32"

  tags = {
    Environment = var.stage
    ManagedBy   = "terraform"
  }
}

output "cluster_name" {
  value = module.migration_assistant.cluster_name
}

output "ecr_repository_url" {
  value = module.migration_assistant.ecr_repository_url
}

output "kubectl_config" {
  value = "aws eks update-kubeconfig --name ${module.migration_assistant.cluster_name} --region ${var.region}"
}
