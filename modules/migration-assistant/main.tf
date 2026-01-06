data "aws_region" "current" {}
data "aws_availability_zones" "available" { state = "available" }

locals {
  region       = data.aws_region.current.name
  cluster_name = "ma-${var.stage}-${local.region}"
  azs          = var.azs != null ? var.azs : slice(data.aws_availability_zones.available.names, 0, 2)

  vpc_id     = var.create_vpc ? module.vpc[0].vpc_id : var.vpc_id
  subnet_ids = var.create_vpc ? module.vpc[0].private_subnets : var.subnet_ids

  tags = merge(var.tags, {
    Project = var.name
    Stage   = var.stage
  })
}

#---------------------------------------------------------------
# VPC
#---------------------------------------------------------------
module "vpc" {
  count   = var.create_vpc ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.9"

  name = "${var.name}-${var.stage}"
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets  = [cidrsubnet(var.vpc_cidr, 2, 0), cidrsubnet(var.vpc_cidr, 2, 1)]
  private_subnets = [cidrsubnet(var.vpc_cidr, 2, 2), cidrsubnet(var.vpc_cidr, 2, 3)]

  enable_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  tags = local.tags
}

module "vpc_endpoints" {
  count   = var.create_vpc ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.9"

  vpc_id = module.vpc[0].vpc_id

  endpoints = {
    s3      = { service = "s3", service_type = "Gateway", route_table_ids = module.vpc[0].private_route_table_ids }
    ecr_api = { service = "ecr.api", private_dns_enabled = true, subnet_ids = module.vpc[0].private_subnets }
    ecr_dkr = { service = "ecr.dkr", private_dns_enabled = true, subnet_ids = module.vpc[0].private_subnets }
    logs    = { service = "logs", private_dns_enabled = true, subnet_ids = module.vpc[0].private_subnets }
    efs     = { service = "elasticfilesystem", private_dns_enabled = true, subnet_ids = module.vpc[0].private_subnets }
  }

  tags = local.tags
}

#---------------------------------------------------------------
# EKS
#---------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.cluster_name
  cluster_version = var.eks_version

  vpc_id     = local.vpc_id
  subnet_ids = local.subnet_ids

  cluster_endpoint_public_access  = var.eks_public_access
  cluster_endpoint_private_access = true

  cluster_compute_config = {
    enabled    = true
    node_pools = var.eks_node_pools
  }

  enable_cluster_creator_admin_permissions = true

  tags = local.tags
}

#---------------------------------------------------------------
# ECR
#---------------------------------------------------------------
resource "aws_ecr_repository" "main" {
  name                 = "${var.name}-ecr-${var.stage}-${local.region}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
  tags = local.tags
}

#---------------------------------------------------------------
# IAM: Pod Identity
#---------------------------------------------------------------
resource "aws_iam_role" "pod_identity" {
  name        = "${local.cluster_name}-migrations-role"
  description = "Migrations pod identity role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "pod_identity_ecr" {
  role       = aws_iam_role.pod_identity.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

resource "aws_iam_role_policy" "pod_identity" {
  name = "MigrationsPodPolicy"
  role = aws_iam_role.pod_identity.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["aoss:APIAccessAll", "es:ESHttp*", "elasticfilesystem:Client*", "logs:*", "s3:*", "secretsmanager:*", "xray:Put*"]
      Resource = "*"
    }, {
      Effect   = "Allow"
      Action   = "iam:PassRole"
      Resource = aws_iam_role.snapshot.arn
    }]
  })
}

#---------------------------------------------------------------
# IAM: Snapshot Role
#---------------------------------------------------------------
resource "aws_iam_role" "snapshot" {
  name        = "${local.cluster_name}-snapshot-role"
  description = "OpenSearch snapshot role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "es.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "snapshot" {
  name = "SnapshotPolicy"
  role = aws_iam_role.snapshot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:aws:s3:::migrations-*" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "arn:aws:s3:::migrations-*/*" }
    ]
  })
}

#---------------------------------------------------------------
# Pod Identity Associations
#---------------------------------------------------------------
resource "aws_eks_pod_identity_association" "main" {
  for_each = toset([
    "build-images-service-account",
    "argo-workflow-executor",
    "migrations-service-account",
    "migration-console-access-role",
    "otel-collector"
  ])

  cluster_name    = module.eks.cluster_name
  namespace       = "ma"
  service_account = each.key
  role_arn        = aws_iam_role.pod_identity.arn
}

#---------------------------------------------------------------
# Helm Chart (opt-in)
#---------------------------------------------------------------
data "http" "latest_release" {
  count = var.deploy_helm_chart && var.helm_chart_version == null ? 1 : 0
  url   = "https://api.github.com/repos/opensearch-project/opensearch-migrations/releases/latest"
}

locals {
  helm_version = var.deploy_helm_chart ? (
    var.helm_chart_version != null ? var.helm_chart_version : jsondecode(data.http.latest_release[0].response_body).tag_name
  ) : null

  image_tag       = local.helm_version
  public_ecr_base = "public.ecr.aws/opensearchproject"
  chart_url       = var.deploy_helm_chart ? "https://github.com/opensearch-project/opensearch-migrations/releases/download/${local.helm_version}/migration-assistant-${local.helm_version}.tgz" : null
  chart_path      = var.deploy_helm_chart ? "${path.module}/.helm-cache/migration-assistant-${local.helm_version}.tgz" : null
}

resource "terraform_data" "download_helm_chart" {
  count = var.deploy_helm_chart ? 1 : 0

  triggers_replace = [local.helm_version]

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ${path.module}/.helm-cache
      # Try OCI registry first
      helm pull oci://public.ecr.aws/opensearchproject/migration-assistant --version ${local.helm_version} -d ${path.module}/.helm-cache 2>/dev/null && \
        mv ${path.module}/.helm-cache/migration-assistant-*.tgz ${local.chart_path} && exit 0
      # Try GitHub release
      curl -fsSL -o ${local.chart_path} ${local.chart_url} 2>/dev/null && exit 0
      # Fallback to git clone
      echo "Falling back to git clone..."
      rm -rf ${path.module}/.helm-cache/repo
      git clone --depth 1 --branch ${local.helm_version} https://github.com/opensearch-project/opensearch-migrations.git ${path.module}/.helm-cache/repo
      helm package ${path.module}/.helm-cache/repo/deployment/k8s/charts/aggregates/migrationAssistantWithArgo -d ${path.module}/.helm-cache
      mv ${path.module}/.helm-cache/migration-assistant-*.tgz ${local.chart_path}
      rm -rf ${path.module}/.helm-cache/repo
    EOT
  }
}

resource "helm_release" "migration_assistant" {
  count = var.deploy_helm_chart ? 1 : 0

  name             = "ma"
  namespace        = "ma"
  create_namespace = true
  chart            = local.chart_path
  timeout          = 900
  wait             = false

  values = [
    yamlencode({
      stageName = var.stage
      aws = {
        configureAwsEksResources = true
        region                   = local.region
        account                  = data.aws_caller_identity.current.account_id
      }
      cluster = {
        isEKS = true
        name  = module.eks.cluster_name
      }
      conditionalPackageInstalls = {
        localstack = false
        jaeger     = false
      }
      defaultBucketConfiguration = {
        useLocalStack     = false
        deleteOnUninstall = true
        emptyBeforeDelete = true
        snapshotRoleArn   = aws_iam_role.snapshot.arn
      }
      images = var.use_public_images ? {
        captureProxy        = { repository = "${local.public_ecr_base}/opensearch-migrations-traffic-capture-proxy", tag = local.image_tag }
        trafficReplayer     = { repository = "${local.public_ecr_base}/opensearch-migrations-traffic-replayer", tag = local.image_tag }
        reindexFromSnapshot = { repository = "${local.public_ecr_base}/opensearch-migrations-reindex-from-snapshot", tag = local.image_tag }
        migrationConsole    = { repository = "${local.public_ecr_base}/opensearch-migrations-console", tag = local.image_tag }
        installer           = { repository = "${local.public_ecr_base}/opensearch-migrations-console", tag = local.image_tag }
      } : {
        captureProxy        = { repository = aws_ecr_repository.main.repository_url, tag = "migrations_capture_proxy_latest" }
        trafficReplayer     = { repository = aws_ecr_repository.main.repository_url, tag = "migrations_traffic_replayer_latest" }
        reindexFromSnapshot = { repository = aws_ecr_repository.main.repository_url, tag = "migrations_reindex_from_snapshot_latest" }
        migrationConsole    = { repository = aws_ecr_repository.main.repository_url, tag = "migrations_migration_console_latest" }
        installer           = { repository = aws_ecr_repository.main.repository_url, tag = "migrations_migration_console_latest" }
      }
    })
  ]

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.main,
    terraform_data.download_helm_chart
  ]
}

data "aws_caller_identity" "current" {}
