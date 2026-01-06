terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4.0"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "helm" {
  kubernetes = {
    host                   = module.migration_assistant.cluster_endpoint
    cluster_ca_certificate = base64decode(module.migration_assistant.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.migration_assistant.cluster_name, "--region", var.region]
    }
  }
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "stage" {
  description = "Stage identifier"
  type        = string
  default     = "dev"
}

variable "deploy_helm_chart" {
  description = "Deploy Migration Assistant helm chart"
  type        = bool
  default     = false
}

module "migration_assistant" {
  source = "github.com/AndreKurait/migration-assistant-terraform//modules/migration-assistant"

  stage             = var.stage
  create_vpc        = true
  deploy_helm_chart = var.deploy_helm_chart

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

output "vpc_id" {
  value = module.migration_assistant.vpc_id
}

output "kubectl_config" {
  value = "aws eks update-kubeconfig --name ${module.migration_assistant.cluster_name} --region ${var.region}"
}
