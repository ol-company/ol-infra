# Bí mật sinh bởi Terraform, lưu trong AWS Secrets Manager, tiêm vào container lúc khởi động.
# Lưu ý: giá trị cũng nằm trong Terraform state → state bucket phải mã hóa và hạn chế quyền đọc (Bước 6).
locals {
  generated_secrets = toset([
    "db/keycloak", "db/iam-app", "db/iam-migrator", "db/warehouse-app", "db/warehouse-migrator", "db/bff-app", "db/bff-migrator",
    "keycloak/admin", "clients/ol-bff", "clients/ol-iam-service", "clients/ol-warehouse-service",
  ])
}

resource "random_password" "this" {
  for_each = local.generated_secrets
  length   = 40
  special  = false # Tránh ký tự đặc biệt gây lỗi trong chuỗi kết nối/URL
  # Đổi giá trị secret_rotation["<khóa>"] trong terraform.tfvars (qua PR) → sinh mật khẩu mới (Bước 8, mục xoay vòng)
  keepers = { rotation = lookup(var.secret_rotation, each.key, "0") }
}

resource "random_bytes" "bff_session_key" {
  length  = 32 # AES-256
  keepers = { rotation = lookup(var.secret_rotation, "bff/session-key", "0") } # Xoay vòng = mọi người phải đăng nhập lại
}

resource "aws_secretsmanager_secret" "this" {
  for_each                = setunion(local.generated_secrets, ["bff/session-key", "ses/smtp"])
  name                    = "ol/${var.env}/${each.key}"
  recovery_window_in_days = var.env == "prod" ? 30 : 7 # Xóa nhầm vẫn khôi phục được trong khoảng này
}

resource "aws_secretsmanager_secret_version" "generated" {
  for_each      = local.generated_secrets
  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = random_password.this[each.key].result
}

resource "aws_secretsmanager_secret_version" "bff_session_key" {
  secret_id     = aws_secretsmanager_secret.this["bff/session-key"].id
  secret_string = random_bytes.bff_session_key.base64
}

resource "aws_secretsmanager_secret_version" "ses_smtp" {
  secret_id = aws_secretsmanager_secret.this["ses/smtp"].id
  secret_string = jsonencode({
    username = aws_iam_access_key.ses_smtp.id
    password = aws_iam_access_key.ses_smtp.ses_smtp_password_v4
  })
}

locals {
  # Đổi khi xoay vòng bí mật → task definition của service đổi → ECS rolling để task nạp bí mật mới (Bước 8)
  secrets_rotation = substr(sha1(jsonencode(var.secret_rotation)), 0, 12)
  secret = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
  # Bí mật master của RDS dạng JSON {username, password}; ECS đọc từng khóa bằng hậu tố ":khóa::"
  rds_master_secret = aws_db_instance.this.master_user_secret[0].secret_arn
}
