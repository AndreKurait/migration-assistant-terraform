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
  region = "us-east-2"
}

module "migration_assistant" {
  source = "github.com/AndreKurait/migration-assistant-terraform//modules/migration-assistant"

  stage      = "dev"
  create_vpc = true

  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

output "cluster_name" {
  value = module.migration_assistant.cluster_name
}

output "ecr_repository_url" {
  value = module.migration_assistant.ecr_repository_url
}

output "vpc_id" {
  value = module.migration_assistant.vpc_id
}

output "kubectl_config" {
  value = "aws eks update-kubeconfig --name ${module.migration_assistant.cluster_name} --region us-east-2"
}
