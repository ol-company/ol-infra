# Cảnh báo theo SLO (burn rate) + tín hiệu hạ tầng, gửi email qua SNS. Dashboard tổng quan.
# SLO khả dụng 99,5% → ngân sách lỗi 0,5%.
#  - Đốt nhanh: tỉ lệ lỗi > 14,4 × 0,5% = 7,2% trong cả 1 giờ và 5 phút  → cạn ngân sách tháng trong ~2 ngày
#  - Đốt chậm : tỉ lệ lỗi > 6 × 0,5%   = 3%   trong cả 6 giờ và 30 phút → cạn trong ~5 ngày
resource "aws_sns_topic" "alarms" {
  name = "${local.name}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email # AWS gửi email xác nhận — phải bấm xác nhận mới nhận cảnh báo
}

locals {
  lb_dim = aws_lb.this.arn_suffix
  burn_windows = {
    fast-long  = { period = 3600, threshold = 0.072 }
    fast-short = { period = 300, threshold = 0.072 }
    slow-long  = { period = 21600, threshold = 0.03 }
    slow-short = { period = 1800, threshold = 0.03 }
  }
}

resource "aws_cloudwatch_metric_alarm" "error_ratio" {
  for_each            = local.burn_windows
  alarm_name          = "${local.name}-error-ratio-${each.key}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"
  actions_enabled     = false # Chỉ dùng làm thành phần của composite alarm bên dưới

  metric_query {
    id          = "ratio"
    expression  = "(FILL(e5,0) + FILL(t5,0)) / IF(FILL(req,0) > 0, req, 1)"
    label       = "Tỉ lệ lỗi 5xx"
    return_data = true
  }
  metric_query {
    id = "e5"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = { LoadBalancer = local.lb_dim }
      period      = each.value.period
      stat        = "Sum"
    }
  }
  metric_query {
    id = "t5"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = local.lb_dim }
      period      = each.value.period
      stat        = "Sum"
    }
  }
  metric_query {
    id = "req"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = local.lb_dim }
      period      = each.value.period
      stat        = "Sum"
    }
  }
}

resource "aws_cloudwatch_composite_alarm" "slo_fast_burn" {
  alarm_name    = "${local.name}-slo-fast-burn"
  alarm_rule    = "ALARM(\"${aws_cloudwatch_metric_alarm.error_ratio["fast-long"].alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.error_ratio["fast-short"].alarm_name}\")"
  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_composite_alarm" "slo_slow_burn" {
  alarm_name    = "${local.name}-slo-slow-burn"
  alarm_rule    = "ALARM(\"${aws_cloudwatch_metric_alarm.error_ratio["slow-long"].alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.error_ratio["slow-short"].alarm_name}\")"
  alarm_actions = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${local.name}-latency-p95"
  alarm_description   = "p95 thời gian phản hồi > 300 ms trong 15 phút (NFR Bước 0)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = local.lb_dim }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 3
  threshold           = 0.3
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each            = aws_lb_target_group.this
  alarm_name          = "${local.name}-unhealthy-${each.key}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = local.lb_dim, TargetGroup = each.value.arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each = {
    cpu     = { metric = "CPUUtilization", stat = "Average", op = "GreaterThanThreshold", threshold = 80 }
    storage = { metric = "FreeStorageSpace", stat = "Minimum", op = "LessThanThreshold", threshold = 2147483648 }
    memory  = { metric = "FreeableMemory", stat = "Minimum", op = "LessThanThreshold", threshold = 134217728 }
  }
  alarm_name          = "${local.name}-rds-${each.key}"
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = each.value.stat
  period              = 300
  evaluation_periods  = 3
  threshold           = each.value.threshold
  comparison_operator = each.value.op
  treat_missing_data  = var.office_hours_only ? "notBreaching" : "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "Request & lỗi 5xx", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.lb_dim],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "Độ trễ p50/p95/p99 (giây)", region = var.region, period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.lb_dim, { stat = "p50" }],
            ["...", { stat = "p95" }],
            ["...", { stat = "p99" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title = "CPU theo service (%)", region = var.region, stat = "Average", period = 60
          metrics = [for s in keys(module.service) : ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", s]]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "RDS", region = var.region, stat = "Average", period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.this.identifier],
            [".", "DatabaseConnections", ".", "."],
          ]
        }
      },
    ]
  })
}
