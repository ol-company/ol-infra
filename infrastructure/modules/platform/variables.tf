# Biến đầu vào của toàn bộ nền tảng một môi trường. Giá trị cụ thể nằm ở envs/<env>/terraform.tfvars.
variable "env" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env phải là dev, staging hoặc prod."
  }
}
variable "region" { type = string }
variable "root_domain" {
  type        = string
  description = "Domain gốc có hosted zone ở account shared, ví dụ ol.example.com"
}
variable "shared_account_id" { type = string }
variable "deploy" {
  type        = any
  description = "Nội dung deploy/<env>/<module>.yaml đã yamldecode, theo tên module"
}
variable "db_bootstrap_sql" {
  type        = string
  description = "Nội dung ol-infra/db/bootstrap.sql"
}

# --- Mạng ---
variable "vpc_cidr" { type = string }
variable "az_count" {
  type    = number
  default = 2
}
variable "enable_nat" {
  type    = bool
  default = false
}
variable "single_nat" {
  type    = bool
  default = true
}

# --- Database ---
variable "rds_instance_class" { type = string }
variable "rds_engine_major" {
  type    = string
  default = "17"
}
variable "rds_multi_az" {
  type    = bool
  default = false
}
variable "rds_allocated_storage" {
  type    = number
  default = 20
}
variable "rds_max_allocated_storage" {
  type    = number
  default = 100
}
variable "rds_backup_retention_days" {
  type    = number
  default = 7
}
variable "deletion_protection" {
  type    = bool
  default = false
}

# --- Vận hành ---
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "waf_enabled" {
  type    = bool
  default = false
}
variable "waf_rate_limit" {
  type        = number
  default     = 2000
  description = "Số request tối đa / 5 phút / IP. Tăng tạm thời khi load test từ một IP"
}
variable "alarm_email" { type = string }
variable "budget_usd" { type = number }
variable "office_hours_only" {
  type        = bool
  default     = false
  description = "Tắt service + RDS ngoài giờ làm việc để tiết kiệm (chỉ nên dùng cho dev/staging)"
}
variable "use_spot" {
  type    = bool
  default = false
}
variable "adot_enabled" {
  type    = bool
  default = true
}
variable "backup_plan_enabled" {
  type    = bool
  default = false
}
variable "keycloak_admin_cidrs" {
  type        = list(string)
  default     = []
  description = "IP được truy cập /admin của Keycloak qua ALB (break-glass). Rỗng = chặn hoàn toàn"
}
variable "ses_verified_recipients" {
  type        = list(string)
  default     = []
  description = "Khi SES còn ở sandbox: email người nhận phải được xác minh trước"
}

variable "secret_rotation" {
  type        = map(string)
  default     = {}
  description = "Khóa bí mật → nhãn xoay vòng (ví dụ { \"db/iam-app\" = \"2026-11-03\" }). Đổi nhãn = sinh bí mật mới và triển khai lại service"
}
