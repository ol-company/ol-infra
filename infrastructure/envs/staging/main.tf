# =============================================================================
# Môi trường <env>: cùng một module "platform", khác nhau ở terraform.tfvars.
# Trạng thái deploy (image digest, CPU/RAM, số task) đọc từ ol-infra/deploy/<env>/*.yaml.
# Chạy:  terraform init -backend-config=backend.hcl && terraform plan
# =============================================================================
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.7" }
  }
  backend "s3" {} # Cấu hình trong backend.hcl (bucket ở account shared, khóa bằng lockfile)
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "ol-platform", Environment = var.env, ManagedBy = "terraform", Repository = "ol-infra" }
  }
}

# Provider trỏ sang account shared để ghi bản ghi DNS (hosted zone nằm ở đó)
provider "aws" {
  alias  = "dns"
  region = var.region
  assume_role {
    role_arn     = "arn:aws:iam::${var.shared_account_id}:role/ol-dns-records"
    session_name = "ol-${var.env}-dns"
  }
}

locals {
  modules = ["iam-service", "warehouse-service", "bff", "web-admin", "keycloak", "keycloak-config"]
  deploy  = { for m in local.modules : m => yamldecode(file("${path.module}/../../../deploy/${var.env}/${m}.yaml")) }
}

module "platform" {
  source    = "../../modules/platform"
  providers = { aws = aws, aws.dns = aws.dns }

  env               = var.env
  region            = var.region
  root_domain       = var.root_domain
  shared_account_id = var.shared_account_id
  deploy            = local.deploy
  db_bootstrap_sql  = file("${path.module}/../../../db/bootstrap.sql")

  vpc_cidr                  = var.vpc_cidr
  az_count                  = var.az_count
  enable_nat                = var.enable_nat
  single_nat                = var.single_nat
  rds_instance_class        = var.rds_instance_class
  rds_multi_az              = var.rds_multi_az
  rds_backup_retention_days = var.rds_backup_retention_days
  deletion_protection       = var.deletion_protection
  log_retention_days        = var.log_retention_days
  waf_enabled               = var.waf_enabled
  waf_rate_limit            = var.waf_rate_limit
  secret_rotation           = var.secret_rotation
  alarm_email               = var.alarm_email
  budget_usd                = var.budget_usd
  office_hours_only         = var.office_hours_only
  use_spot                  = var.use_spot
  backup_plan_enabled       = var.backup_plan_enabled
  keycloak_admin_cidrs      = var.keycloak_admin_cidrs
  ses_verified_recipients   = var.ses_verified_recipients
}

output "platform" {
  value = module.platform
}
