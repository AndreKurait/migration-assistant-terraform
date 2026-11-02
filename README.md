# Migration Assistant Terraform Module

Reusable Terraform module for deploying Migration Assistant for Amazon OpenSearch Service infrastructure.

**Status: experimental infrastructure module.** Local validation and mocked
chart-download tests do not establish a working deployment or production-ready
permissions. Pin a reviewed Git revision when consuming the module; the examples
below follow the repository's default branch.

Review these existing defaults before applying:

- The pod role grants broad access to S3, Secrets Manager, OpenSearch, EFS, and
  other services, including `iam:PassRole` across the account. Scope permissions
  to the resources and workflows you need.
- The EKS endpoint is public by default, and the cluster creator receives admin
  permissions. Configure endpoint access and administration for your environment.
- ECR uses `force_delete`; Helm values enable bucket emptying/deletion on
  uninstall. Review data retention before destroying or uninstalling anything.
- Selecting the latest Helm release is not reproducible. Set
  `helm_chart_version` explicitly for a reviewed deployment.

## Usage

### Basic - Create New VPC

```hcl
module "migration_assistant" {
  source = "github.com/AndreKurait/migration-assistant-terraform//modules/migration-assistant"

  stage = "dev"
}
```

### Import Existing VPC

```hcl
module "migration_assistant" {
  source = "github.com/AndreKurait/migration-assistant-terraform//modules/migration-assistant"

  stage      = "prod"
  create_vpc = false
  vpc_id     = "vpc-xxx"
  subnet_ids = ["subnet-xxx", "subnet-yyy"]
}
```

### Full Configuration

```hcl
module "migration_assistant" {
  source = "github.com/AndreKurait/migration-assistant-terraform//modules/migration-assistant"

  name           = "my-migration"
  stage          = "prod"
  eks_version    = "1.32"
  
  create_vpc     = true
  vpc_cidr       = "10.0.0.0/16"
  azs            = ["us-east-1a", "us-east-1b"]
  
  eks_public_access = false
  eks_node_pools    = ["general-purpose", "system"]

  # Deploy helm chart (requires helm provider)
  deploy_helm_chart  = true
  helm_chart_version = "2.6.1"  # Optional, defaults to latest
  use_public_images  = true

  # AWS Solutions tracking
  enable_app_registry = true

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
| deploy_helm_chart | Deploy Migration Assistant helm chart | bool | false |
| helm_chart_version | Helm chart version (defaults to latest) | string | null |
| use_public_images | Use public ECR images | bool | true |
| enable_app_registry | Enable AWS App Registry for Solutions tracking | bool | true |
| solution_version | Solution version for App Registry | string | "2.0.0" |
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
| app_registry_arn | AWS App Registry application ARN |

## AWS Solutions Tracking

This module integrates with AWS App Registry for Solutions tracking (Solution ID: SO0290). This enables:
- Tracking all resources deployed by the solution
- Cost allocation and reporting
- Centralized resource management

To disable App Registry integration, set `enable_app_registry = false`.

## Examples

See [examples/complete](./examples/complete) for a configuration example. It
requires AWS credentials and a Helm provider that can reach the resulting
cluster; it is not an offline deployment test.

## Local validation

```sh
terraform fmt -check -recursive
python3 -m unittest discover -s tests -v
shellcheck modules/migration-assistant/scripts/fetch-chart.sh
terraform -chdir=modules/migration-assistant init -backend=false
terraform -chdir=modules/migration-assistant validate
```

Initialization downloads public modules/providers; validation does not apply
infrastructure. The Python tests replace `curl`, `git`, and `helm` with local
stubs and make no network or AWS requests.

When `deploy_helm_chart` is enabled, the machine running Terraform needs Bash,
curl, Git, Python 3, and Helm. The fetcher validates the release tag, stages downloads in
a temporary directory, and replaces the cached chart only after `helm show chart`
accepts it. A missing release asset (HTTP 404) triggers packaging from that source
tag; transport errors, server errors, and packaging failures stop the operation.
Downloads and fallback source clones each have a 120-second limit. Override the
clone limit with `CHART_SOURCE_TIMEOUT_SECONDS` if needed; timeout terminates
the clone and its transport processes without replacing the existing cache.
This verifies chart readability, not artifact signatures or deployment compatibility.

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
