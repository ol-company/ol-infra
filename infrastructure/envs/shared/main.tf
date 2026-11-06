# =============================================================================
# Tài nguyên dùng chung ở account "shared": ECR (image cho mọi môi trường), hosted zone DNS, ngân sách.
# =============================================================================
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "ol-platform", Environment = "shared", ManagedBy = "terraform", Repository = "ol-infra" }
  }
}

variable "region" { type = string }
variable "root_domain" { type = string }
variable "organization_id" {
  type        = string
  description = "ID của AWS Organization (o-xxxxxxxxxx): chỉ account trong tổ chức mới kéo được image"
}
variable "alarm_email" { type = string }
variable "budget_usd" { type = number }

locals {
  modules = ["iam-service", "warehouse-service", "bff", "web-admin", "keycloak", "keycloak-config"]
}

resource "aws_ecr_repository" "this" {
  for_each             = toset(local.modules)
  name                 = "ol/${each.key}"
  image_tag_mutability = "IMMUTABLE" # Tag đã push không ghi đè được → truy vết chắc chắn
  image_scanning_configuration {
    scan_on_push = true # Quét lỗ hổng cơ bản khi push (bổ sung cho Trivy trong pipeline)
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Cho mọi account trong Organization kéo image (dev/staging/prod)
resource "aws_ecr_repository_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OrgPull"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
      Condition = { StringEquals = { "aws:PrincipalOrgID" = var.organization_id } }
    }]
  })
}

# Giữ 100 image gần nhất mỗi repo; image đang deploy luôn nằm trong số này nếu phát hành đều đặn
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Giu 100 image gan nhat"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 100 }
      action       = { type = "expire" }
    }]
  })
}

# Hosted zone của domain. Sau khi tạo: trỏ NS ở nơi mua domain về 4 name server trong output.
resource "aws_route53_zone" "root" {
  name = var.root_domain
}

resource "aws_budgets_budget" "shared" {
  name         = "ol-shared-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alarm_email]
  }
}

output "ecr_registry" { value = split("/", aws_ecr_repository.this["bff"].repository_url)[0] }
output "name_servers" { value = aws_route53_zone.root.name_servers }
output "zone_id" { value = aws_route53_zone.root.zone_id }
