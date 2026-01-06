# Migration Assistant Terraform Module

Reusable Terraform module for deploying Migration Assistant for Amazon OpenSearch Service infrastructure.

## Usage

### Basic - Create New VPC

```hcl
module "migration_assistant" {
  source = "github.com/your-org/migration-assistant-terraform//modules/migration-assistant"

  stage = "dev"
}
```

### Import Existing VPC

```hcl
module "migration_assistant" {
  source = "github.com/your-org/migration-assistant-terraform//modules/migration-assistant"

  stage      = "prod"
  create_vpc = false
  vpc_id     = "vpc-xxx"
  subnet_ids = ["subnet-xxx", "subnet-yyy"]
}
```

### Full Configuration

```hcl
module "migration_assistant" {
  source = "github.com/your-org/migration-assistant-terraform//modules/migration-assistant"

  name           = "my-migration"
  stage          = "prod"
  eks_version    = "1.32"
  
  create_vpc     = true
  vpc_cidr       = "10.0.0.0/16"
  azs            = ["us-east-1a", "us-east-1b"]
  
  eks_public_access = false
  eks_node_pools    = ["general-purpose", "system"]

  tags = {
    Environment = "production"
    Team        = "platform"
  }
}
```

## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| name | Name prefix | string | "migration-assistant" |
| stage | Stage identifier | string | required |
| eks_version | Kubernetes version | string | "1.32" |
| create_vpc | Create new VPC | bool | true |
| vpc_id | Existing VPC ID | string | null |
| subnet_ids | Existing subnet IDs | list(string) | [] |
| vpc_cidr | VPC CIDR | string | "10.212.0.0/16" |
| azs | Availability zones | list(string) | auto |
| eks_public_access | Enable public endpoint | bool | true |
| eks_node_pools | Auto Mode node pools | list(string) | ["general-purpose", "system"] |
| tags | Additional tags | map(string) | {} |

## Outputs

| Name | Description |
|------|-------------|
| cluster_name | EKS cluster name |
| cluster_endpoint | EKS API endpoint |
| vpc_id | VPC ID |
| ecr_repository_url | ECR repository URL |
| pod_identity_role_arn | Pod identity role ARN |
| snapshot_role_arn | OpenSearch snapshot role ARN |

## Examples

See [examples/complete](./examples/complete) for a working example.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         VPC                                  │
│  ┌─────────────────┐          ┌─────────────────┐          │
│  │  Public Subnet  │          │  Public Subnet  │          │
│  │    (NAT GW)     │          │    (NAT GW)     │          │
│  └────────┬────────┘          └────────┬────────┘          │
│           │                            │                    │
│  ┌────────▼────────┐          ┌────────▼────────┐          │
│  │ Private Subnet  │          │ Private Subnet  │          │
│  │   (EKS Nodes)   │          │   (EKS Nodes)   │          │
│  └─────────────────┘          └─────────────────┘          │
│                                                             │
│  VPC Endpoints: S3, ECR, CloudWatch Logs, EFS              │
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │   EKS Auto Mode   │
                    │   (K8s 1.32)      │
                    └───────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
         ┌────────┐     ┌──────────┐    ┌──────────┐
         │  ECR   │     │ Pod IAM  │    │ Snapshot │
         │  Repo  │     │  Roles   │    │   Role   │
         └────────┘     └──────────┘    └──────────┘
```
