# =============================================================================
# BOOTSTRAP account "shared" — chạy BẰNG TAY một lần với quyền admin (aws sso login).
# Tạo: bucket Terraform state, OIDC provider của GitHub, role cho GitHub Actions
# (push ECR, deploy envs/shared, plan), role ghi DNS cho các account môi trường.
# Lần đầu chạy với state local, sau đó chuyển state lên chính bucket vừa tạo (xem docs/06).
# =============================================================================
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {} # Lần đầu chạy với backend_override.tf (state local), sau đó -migrate-state (docs/06 mục 6.4)
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

variable "region" { type = string }
variable "aws_profile" { type = string }
variable "github_org" { type = string }
variable "organization_id" { type = string }
variable "env_account_ids" {
  type        = map(string)
  description = "dev/staging/prod → AWS account id"
}

data "aws_caller_identity" "me" {}

# ---------------- Terraform state ----------------
resource "aws_s3_bucket" "state" {
  bucket = "ol-tfstate-${data.aws_caller_identity.me.account_id}"
  lifecycle {
    prevent_destroy = true # Mất state = mất khả năng quản lý hạ tầng bằng code
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # Khôi phục được phiên bản state cũ khi apply lỗi
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3: account khác (dev/staging/prod) đọc được; khóa KMS do AWS quản lý (aws/s3) KHÔNG chia sẻ chéo account
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Account môi trường chỉ đọc/ghi được đúng thư mục state của mình
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }],
      flatten([for env, acct in var.env_account_ids : [
        {
          Sid       = "List${title(env)}"
          Effect    = "Allow"
          Principal = { AWS = "arn:aws:iam::${acct}:root" }
          Action    = "s3:ListBucket"
          Resource  = aws_s3_bucket.state.arn
          Condition = {
            StringLike = { "s3:prefix" = ["envs/${env}/*"] }
            ArnLike    = { "aws:PrincipalArn" = "arn:aws:iam::${acct}:role/ol-gha-*" }
          }
        },
        {
          Sid       = "Rw${title(env)}"
          Effect    = "Allow"
          Principal = { AWS = "arn:aws:iam::${acct}:root" }
          Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource  = "${aws_s3_bucket.state.arn}/envs/${env}/*"
          Condition = { ArnLike = { "aws:PrincipalArn" = "arn:aws:iam::${acct}:role/ol-gha-*" } }
        },
      ]]),
    )
  })
}

# ---------------- GitHub OIDC ----------------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  oidc_arn = aws_iam_openid_connect_provider.github.arn
  trust = { for name, subs in {
    ecr_push = ["repo:${var.github_org}/ol-*:ref:refs/heads/main"]
    deploy   = ["repo:${var.github_org}/ol-infra:ref:refs/heads/main"]
    plan     = ["repo:${var.github_org}/ol-infra:pull_request", "repo:${var.github_org}/ol-infra:ref:refs/heads/main"]
    } : name => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = { Federated = local.oidc_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
          StringLike   = { "token.actions.githubusercontent.com:sub" = subs } # Chỉ đúng repo/nhánh được phép
        }
      }]
  }) }
}

# Push image: chỉ nhánh main của các repo ol-* (PR chỉ build + quét, không push)
resource "aws_iam_role" "ecr_push" {
  name                 = "ol-gha-ecr-push"
  assume_role_policy   = local.trust.ecr_push
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.ecr_push.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
        "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages"]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.me.account_id}:repository/ol/*"
      },
    ]
  })
}

resource "aws_iam_role" "deploy" {
  name               = "ol-gha-deploy"
  assume_role_policy = local.trust.deploy
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess" # Chỉ main của ol-infra; thu hẹp ở Bước 8
}

resource "aws_iam_role" "plan" {
  name               = "ol-gha-plan"
  assume_role_policy = local.trust.plan
}

resource "aws_iam_role_policy_attachment" "plan" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Role cho account môi trường ghi bản ghi DNS vào hosted zone ở đây
resource "aws_iam_role" "dns_records" {
  name = "ol-dns-records"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = [for acct in values(var.env_account_ids) : "arn:aws:iam::${acct}:root"] }
      Action    = "sts:AssumeRole"
      Condition = { ArnLike = { "aws:PrincipalArn" = [for acct in values(var.env_account_ids) : "arn:aws:iam::${acct}:role/ol-gha-*"] } }
    }]
  })
}

resource "aws_iam_role_policy" "dns_records" {
  name = "route53-records"
  role = aws_iam_role.dns_records.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets", "route53:GetHostedZone"], Resource = "arn:aws:route53:::hostedzone/*" },
      { Effect = "Allow", Action = ["route53:GetChange"], Resource = "arn:aws:route53:::change/*" },
      { Effect = "Allow", Action = ["route53:ListHostedZones", "route53:ListHostedZonesByName", "route53:ListTagsForResource"], Resource = "*" },
    ]
  })
}

output "state_bucket" { value = aws_s3_bucket.state.id }
output "ecr_push_role_arn" { value = aws_iam_role.ecr_push.arn }
