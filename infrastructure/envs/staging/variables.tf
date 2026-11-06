variable "env" { type = string }
variable "region" { type = string }
variable "root_domain" { type = string }
variable "shared_account_id" { type = string }
variable "vpc_cidr" { type = string }
variable "az_count" { type = number }
variable "enable_nat" { type = bool }
variable "single_nat" { type = bool }
variable "rds_instance_class" { type = string }
variable "rds_multi_az" { type = bool }
variable "rds_backup_retention_days" { type = number }
variable "deletion_protection" { type = bool }
variable "log_retention_days" { type = number }
variable "waf_enabled" { type = bool }
variable "alarm_email" { type = string }
variable "budget_usd" { type = number }
variable "office_hours_only" { type = bool }
variable "use_spot" { type = bool }
variable "backup_plan_enabled" { type = bool }
variable "keycloak_admin_cidrs" {
  type    = list(string)
  default = []
}
variable "ses_verified_recipients" {
  type    = list(string)
  default = []
}
variable "waf_rate_limit" {
  type    = number
  default = 2000
}
variable "secret_rotation" {
  type    = map(string)
  default = {}
}
