# Giá trị script triển khai (scripts/*.sh) đọc bằng "terraform output -json"
output "cluster_name" { value = aws_ecs_cluster.this.name }
output "task_subnet_ids" { value = module.network.task_subnet_ids }
output "app_security_group_id" { value = module.network.app_sg_id }
output "assign_public_ip" { value = module.network.task_public_ip }
output "task_families" { value = { for k, m in module.task : k => m.family } }
output "service_names" { value = { for k, m in module.service : k => m.service_name } }
output "app_url" { value = local.app_url }
output "id_url" { value = "https://${local.id_host}" }
output "log_group" { value = aws_cloudwatch_log_group.app.name }
output "rds_identifier" { value = aws_db_instance.this.identifier }
output "rds_address" { value = aws_db_instance.this.address }
output "rds_subnet_group" { value = aws_db_subnet_group.this.name }
output "db_security_group_id" { value = module.network.db_sg_id }
output "alarm_topic_arn" { value = aws_sns_topic.alarms.arn }
