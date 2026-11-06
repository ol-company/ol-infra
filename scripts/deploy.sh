#!/usr/bin/env bash
# =============================================================================
# Triển khai một môi trường. Dùng trong workflow deploy.yml (đã có quyền AWS qua OIDC).
#   scripts/deploy.sh <dev|staging|prod>
# Trình tự (an toàn khi chạy lại):
#   1. Áp hạ tầng nền + task definition của task một lần (chưa đổi service)
#   2. db-init: tạo/cập nhật role, database (idempotent)
#   3. Migration của từng service — PHẢI tương thích ngược với phiên bản đang chạy (expand/contract)
#   4. Áp toàn bộ (rolling deploy service; ECS tự rollback nếu task mới không khỏe)
#   5. Cấu hình realm Keycloak
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib.sh"
env="${1:?Cần môi trường}"
[[ "$env" =~ ^(dev|staging|prod)$ ]] || die "Môi trường không hợp lệ"
dir="infrastructure/envs/$env"

log "terraform init ($env)"
terraform -chdir="$dir" init -input=false -backend-config=backend.hcl

log "Bước 1: hạ tầng nền + task definition + giá trị bí mật (để db-init dùng mật khẩu mới khi xoay vòng)"
terraform -chdir="$dir" apply -input=false -auto-approve -target=module.platform.module.task \
  -target=module.platform.aws_secretsmanager_secret_version.generated \
  -target=module.platform.aws_secretsmanager_secret_version.bff_session_key

log "Bước 2: khởi tạo database"
run_task "$env" db-init

log "Bước 3: migration"
for m in iam-service warehouse-service bff; do run_task "$env" "$m-migrate"; done

log "Bước 4: triển khai service (rolling, chờ ổn định)"
terraform -chdir="$dir" apply -input=false -auto-approve

log "Bước 5: cấu hình realm Keycloak"
if [[ "$(tf_out "$env" 'task_families["keycloak-config"]')" != "null" ]]; then
  ip=$(keycloak_ip "$env")
  run_task "$env" keycloak-config "{\"containerOverrides\":[{\"name\":\"keycloak-config\",\"environment\":[{\"name\":\"KEYCLOAK_URL\",\"value\":\"http://$ip:8080\"}]}]}"
fi

log "Hoàn tất triển khai $env: $(tf_out "$env" app_url)"
