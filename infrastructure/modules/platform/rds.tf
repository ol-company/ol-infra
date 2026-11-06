# PostgreSQL trên RDS: mã hóa lưu trữ, bắt buộc TLS, backup tự động (PITR), mật khẩu master do RDS quản lý
resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.network.private_subnet_ids # DB không bao giờ có IP public
}

resource "aws_db_parameter_group" "this" {
  name   = "${local.name}-pg${var.rds_engine_major}"
  family = "postgres${var.rds_engine_major}"
  parameter {
    name  = "rds.force_ssl" # Từ chối mọi kết nối không TLS
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement" # Ghi log câu lệnh chạy quá 500 ms để tìm truy vấn chậm
    value = "500"
  }
  parameter {
    name  = "idle_in_transaction_session_timeout" # Hủy phiên treo trong transaction quá 60 giây
    value = "60000"
  }
}

resource "aws_db_instance" "this" {
  identifier                      = local.name
  engine                          = "postgres"
  engine_version                  = var.rds_engine_major # Chỉ định major; RDS chọn minor mặc định và tự vá minor
  instance_class                  = var.rds_instance_class
  allocated_storage               = var.rds_allocated_storage
  max_allocated_storage           = var.rds_max_allocated_storage # Tự tăng dung lượng khi gần đầy
  storage_type                    = "gp3"
  storage_encrypted               = true
  db_name                         = "postgres"
  username                        = "ol_admin"
  manage_master_user_password     = true # Mật khẩu master nằm trong Secrets Manager, RDS tự xoay vòng
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [module.network.db_sg_id]
  parameter_group_name            = aws_db_parameter_group.this.name
  multi_az                        = var.rds_multi_az
  publicly_accessible             = false
  backup_retention_period         = var.rds_backup_retention_days # Point-in-time restore trong khoảng này
  backup_window                   = "18:00-19:00"                 # UTC = 01:00–02:00 giờ Việt Nam
  maintenance_window              = "sun:19:30-sun:20:30"
  auto_minor_version_upgrade      = true
  copy_tags_to_snapshot           = true
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = !var.deletion_protection
  final_snapshot_identifier       = var.deletion_protection ? "${local.name}-final" : null
  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
  ca_cert_identifier              = "rds-ca-rsa2048-g1"
  apply_immediately               = var.env != "prod" # Prod: thay đổi chờ tới cửa sổ bảo trì
}
