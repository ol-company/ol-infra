# Tắt/bật RDS theo giờ làm việc (chỉ khi office_hours_only = true) — tiết kiệm ~60% chi phí DB dev.
resource "aws_iam_role" "scheduler" {
  count = var.office_hours_only ? 1 : 0
  name  = "${local.name}-scheduler"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "scheduler.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  count = var.office_hours_only ? 1 : 0
  name  = "rds-start-stop"
  role  = aws_iam_role.scheduler[0].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["rds:StopDBInstance", "rds:StartDBInstance"], Resource = aws_db_instance.this.arn }]
  })
}

resource "aws_scheduler_schedule" "rds" {
  for_each = var.office_hours_only ? {
    stop  = { cron = "cron(15 20 ? * MON-FRI *)", api = "stopDBInstance" }  # 20:15 sau khi service đã về 0
    start = { cron = "cron(0 7 ? * MON-FRI *)", api = "startDBInstance" }   # 07:00 trước khi service bật lúc 07:30
  } : {}
  name                         = "${local.name}-rds-${each.key}"
  schedule_expression          = each.value.cron
  schedule_expression_timezone = "Asia/Ho_Chi_Minh"
  flexible_time_window {
    mode = "OFF"
  }
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:${each.value.api}"
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({ DbInstanceIdentifier = aws_db_instance.this.identifier })
  }
}
