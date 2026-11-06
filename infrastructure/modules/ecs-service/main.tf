# =============================================================================
# Một service (hoặc một task chạy một lần) trên ECS Fargate:
#  task definition (image theo DIGEST, tài nguyên, biến môi trường, bí mật, log, healthcheck)
#  + ECS service (rolling deploy có circuit breaker tự rollback, Service Connect, ALB)
#  + autoscaling theo CPU + lịch tắt ngoài giờ (tùy chọn)
# =============================================================================
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

variable "name" { type = string }                         # Tên container và service, ví dụ "iam-service"
variable "family" { type = string }                       # Tên task definition, ví dụ "ol-dev-iam-service"
variable "cluster_arn" { type = string }
variable "cluster_name" { type = string }
variable "region" { type = string }
variable "image" { type = string }                        # <registry>/ol/<module>@sha256:...
variable "cpu" { type = number }
variable "memory" { type = number }
variable "command" {
  type    = list(string)
  default = null
}
variable "environment" {
  type    = map(string)
  default = {}
}
variable "secrets" {
  type        = map(string)
  default     = {}
  description = "Tên biến → ARN bí mật trong Secrets Manager (có thể kèm :khóa-json::)"
}
variable "execution_role_arn" { type = string }           # Quyền của ECS agent: kéo image, đọc secret, ghi log
variable "task_role_arn" { type = string }                # Quyền của ứng dụng khi gọi AWS API
variable "log_group_name" { type = string }
variable "container_port" {
  type    = number
  default = 3000
}
variable "health_check_command" {
  type    = list(string)
  default = null
}
variable "readonly_root" {
  type    = bool
  default = true
}
variable "adot_sidecar" {
  type    = bool
  default = false
}
variable "adot_image" {
  type = string
  # [CHƯA XÁC MINH] Thay "latest" bằng tag phiên bản cụ thể (xem trang Releases của aws-otel-collector) — không dùng tag trôi ở prod
  default = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
}
variable "create_service" {
  type    = bool
  default = true
}
variable "desired_count" {
  type    = number
  default = 1
}
variable "min_count" {
  type    = number
  default = 1
}
variable "max_count" {
  type    = number
  default = 1
}
variable "use_spot" {
  type    = bool
  default = false
}
variable "subnet_ids" { type = list(string) }
variable "security_group_ids" { type = list(string) }
variable "assign_public_ip" {
  type    = bool
  default = false
}
variable "target_group_arn" {
  type    = string
  default = null
}
variable "service_connect_namespace_arn" {
  type    = string
  default = null
}
variable "service_connect_server" {
  type        = bool
  default     = false
  description = "true: service khác gọi được qua http://<name>:<port>; false: chỉ là client"
}
variable "office_hours" {
  type        = bool
  default     = false
  description = "true: tự scale về 0 lúc 20:00 và bật lại 07:30 các ngày làm việc (giờ Việt Nam)"
}

locals {
  port_name = "http"
  app_container = merge(
    {
      name                   = var.name
      image                  = var.image
      essential              = true
      readonlyRootFilesystem = var.readonly_root
      stopTimeout            = 30 # SIGTERM → tối đa 30 giây để tắt êm rồi mới SIGKILL
      linuxParameters        = { initProcessEnabled = true }
      portMappings = var.create_service ? [{
        containerPort = var.container_port
        protocol      = "tcp"
        name          = local.port_name
        appProtocol   = "http"
      }] : []
      environment = [for k, v in merge(var.environment, var.adot_sidecar ? { OTEL_EXPORTER_OTLP_ENDPOINT = "http://localhost:4318" } : {}) : { name = k, value = v }]
      secrets     = [for k, v in var.secrets : { name = k, valueFrom = v }]
      mountPoints = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = var.name
          "mode"                  = "non-blocking" # Log chậm không làm treo ứng dụng
          "max-buffer-size"       = "25m"
        }
      }
    },
    var.command == null ? {} : { command = var.command },
    var.health_check_command == null ? {} : {
      healthCheck = { command = var.health_check_command, interval = 15, timeout = 5, retries = 3, startPeriod = 60 }
    },
  )
  adot_container = {
    name      = "otel-collector"
    image     = var.adot_image
    essential = false # Collector lỗi không được làm sập ứng dụng
    cpu       = 64
    memory    = 128
    command   = ["--config=/etc/ecs/ecs-default-config.yaml"] # Cấu hình có sẵn: OTLP → X-Ray + CloudWatch metrics
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.log_group_name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "${var.name}-otel"
      }
    }
  }
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  volume {
    name = "tmp" # Vùng ghi tạm duy nhất khi root filesystem chỉ đọc
  }
  container_definitions = jsonencode(concat([local.app_container], var.adot_sidecar ? [local.adot_container] : []))
}

resource "aws_ecs_service" "this" {
  count                              = var.create_service ? 1 : 0
  name                               = var.name
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.desired_count
  deployment_minimum_healthy_percent = 100 # Rolling: luôn giữ đủ task cũ cho tới khi task mới khỏe
  deployment_maximum_percent         = 200
  enable_execute_command             = false
  propagate_tags                     = "SERVICE"
  wait_for_steady_state              = true # terraform apply chỉ thành công khi service đã ổn định
  health_check_grace_period_seconds  = var.target_group_arn == null ? null : 90

  capacity_provider_strategy {
    capacity_provider = var.use_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  # Task mới không khỏe → ECS tự quay về bản trước; terraform apply báo lỗi
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = var.assign_public_ip
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [1]
    content {
      target_group_arn = var.target_group_arn
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  dynamic "service_connect_configuration" {
    for_each = var.service_connect_namespace_arn == null ? [] : [1]
    content {
      enabled   = true
      namespace = var.service_connect_namespace_arn
      dynamic "service" {
        for_each = var.service_connect_server ? [1] : []
        content {
          port_name      = local.port_name
          discovery_name = var.name
          client_alias {
            port     = var.container_port
            dns_name = var.name # Service khác gọi http://iam-service:3000
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [desired_count] # Autoscaling/lịch tắt điều chỉnh, Terraform không giành lại
  }
}

resource "aws_appautoscaling_target" "this" {
  count              = var.create_service ? 1 : 0
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  count              = var.create_service && var.max_count > var.min_count ? 1 : 0
  name               = "${var.family}-cpu60"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_scheduled_action" "stop" {
  count              = var.create_service && var.office_hours ? 1 : 0
  name               = "${var.family}-stop-evening"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  schedule           = "cron(0 20 ? * MON-FRI *)"
  timezone           = "Asia/Ho_Chi_Minh"
  scalable_target_action {
    min_capacity = 0
    max_capacity = 0
  }
}

resource "aws_appautoscaling_scheduled_action" "start" {
  count              = var.create_service && var.office_hours ? 1 : 0
  name               = "${var.family}-start-morning"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  schedule           = "cron(30 7 ? * MON-FRI *)"
  timezone           = "Asia/Ho_Chi_Minh"
  scalable_target_action {
    min_capacity = var.min_count
    max_capacity = var.max_count
  }
}

output "task_definition_arn" { value = aws_ecs_task_definition.this.arn }
output "family" { value = aws_ecs_task_definition.this.family }
output "service_name" { value = var.create_service ? aws_ecs_service.this[0].name : null }
