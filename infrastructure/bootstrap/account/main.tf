# =============================================================================
# BOOTSTRAP một account môi trường (dev | staging | prod) — chạy BẰNG TAY một lần với quyền admin.
# Tạo OIDC provider + 2 role cho GitHub Actions:
#   ol-gha-plan   : chỉ đọc — terraform plan trên Pull Request và kiểm tra drift
#   ol-gha-deploy : triển khai — CHỈ job gắn GitHub Environment tương ứng (có luật duyệt) mới dùng được
# =============================================================================
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {}
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

variable "region" { type = string }
variable "aws_profile" { type = string }
variable "github_org" { type = string }
variable "env" { type = string }
variable "github_environment" {
  type        = string
  description = "Tên GitHub Environment trong repo ol-infra: dev | staging | production"
}
variable "state_bucket" { type = string }
variable "shared_account_id" { type = string }

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  oidc = aws_iam_openid_connect_provider.github.arn
  trust = { for name, subs in {
    plan   = ["repo:${var.github_org}/ol-infra:pull_request", "repo:${var.github_org}/ol-infra:ref:refs/heads/main"]
    deploy = ["repo:${var.github_org}/ol-infra:environment:${var.github_environment}"]
    } : name => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = { Federated = local.oidc }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
          StringLike   = { "token.actions.githubusercontent.com:sub" = subs }
        }
      }]
  }) }
  common_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:aws:s3:::${var.state_bucket}" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "arn:aws:s3:::${var.state_bucket}/envs/${var.env}/*" },
      { Effect = "Allow", Action = "sts:AssumeRole", Resource = "arn:aws:iam::${var.shared_account_id}:role/ol-dns-records" },
    ]
  })
}

resource "aws_iam_role" "plan" {
  name               = "ol-gha-plan"
  assume_role_policy = local.trust.plan
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_extra" {
  name   = "state-dns"
  role   = aws_iam_role.plan.id
  policy = local.common_policy
}

# Plan cần đọc giá trị secret do Terraform quản lý để so sánh trạng thái
resource "aws_iam_role_policy" "plan_secrets" {
  name = "read-own-secrets"
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = "arn:aws:secretsmanager:${var.region}:*:secret:ol/${var.env}/*" }]
  })
}

resource "aws_iam_role" "deploy" {
  name                 = "ol-gha-deploy"
  assume_role_policy   = local.trust.deploy
  max_session_duration = 7200 # Deploy (apply + migration + smoke test) có thể quá 1 giờ
}

resource "aws_iam_role_policy_attachment" "deploy_admin" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess" # Thu hẹp bằng permissions boundary ở Bước 8
}

resource "aws_iam_role_policy" "deploy_extra" {
  name   = "state-dns"
  role   = aws_iam_role.deploy.id
  policy = local.common_policy
}

output "plan_role_arn" { value = aws_iam_role.plan.arn }
output "deploy_role_arn" { value = aws_iam_role.deploy.arn }
