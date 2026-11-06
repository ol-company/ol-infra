# AWS Backup cho RDS (khuyến nghị prod): bổ sung cho PITR của RDS, giữ bản sao dài hạn.
#  - Hằng ngày, giữ 35 ngày; hằng tháng, giữ 365 ngày (audit log cần lưu ≥ 1 năm)
resource "aws_backup_vault" "this" {
  count = var.backup_plan_enabled ? 1 : 0
  name  = local.name
}

resource "aws_backup_plan" "this" {
  count = var.backup_plan_enabled ? 1 : 0
  name  = local.name
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this[0].name
    schedule          = "cron(0 19 * * ? *)" # 02:00 giờ Việt Nam
    lifecycle {
      delete_after = 35
    }
  }
  rule {
    rule_name         = "monthly"
    target_vault_name = aws_backup_vault.this[0].name
    schedule          = "cron(0 20 1 * ? *)"
    lifecycle {
      delete_after = 365
    }
  }
}

resource "aws_iam_role" "backup" {
  count = var.backup_plan_enabled ? 1 : 0
  name  = "${local.name}-backup"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "backup.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  count      = var.backup_plan_enabled ? 1 : 0
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "rds" {
  count        = var.backup_plan_enabled ? 1 : 0
  name         = "rds"
  plan_id      = aws_backup_plan.this[0].id
  iam_role_arn = aws_iam_role.backup[0].arn
  resources    = [aws_db_instance.this.arn]
}
