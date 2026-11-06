#!/usr/bin/env bash
# Hàm dùng chung cho script triển khai. Dùng: source scripts/lib.sh
set -euo pipefail

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[LỖI] %s\033[0m\n' "$*" >&2; exit 1; }

# Đọc output của Terraform cho môi trường $1 (đã terraform init)
tf_out() { # env key
  terraform -chdir="infrastructure/envs/$1" output -json platform | jq -r ".$2"
}

# IP nội bộ của một task Keycloak đang chạy — task one-off (run-task) không dùng được Service Connect
keycloak_ip() { # env
  local cluster task
  cluster=$(tf_out "$1" cluster_name)
  task=$(aws ecs list-tasks --cluster "$cluster" --service-name keycloak --desired-status RUNNING --query 'taskArns[0]' --output text)
  [[ "$task" != "None" && -n "$task" ]] || die "Không có task Keycloak đang chạy"
  aws ecs describe-tasks --cluster "$cluster" --tasks "$task" \
    --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value | [0]' --output text
}

# Chạy task một lần và chờ kết thúc; mã thoát khác 0 → lỗi. $3 (tùy chọn): JSON overrides cho container
run_task() { # env task-key [overrides-json]
  local env="$1" key="$2" overrides="${3:-}" cluster family subnets sg public task exit_code
  cluster=$(tf_out "$env" cluster_name)
  family=$(tf_out "$env" "task_families[\"$key\"]")
  [[ "$family" != "null" ]] || { echo "Bỏ qua $key (chưa có image)"; return 0; }
  subnets=$(tf_out "$env" task_subnet_ids | jq -r 'join(",")')
  sg=$(tf_out "$env" app_security_group_id)
  public=$(tf_out "$env" assign_public_ip)
  log "Chạy task $family"
  task=$(aws ecs run-task --cluster "$cluster" --task-definition "$family" --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=$([[ $public == true ]] && echo ENABLED || echo DISABLED)}" \
    ${overrides:+--overrides "$overrides"} --started-by "gha-deploy" --query 'tasks[0].taskArn' --output text)
  [[ "$task" != "None" ]] || die "Không khởi chạy được task $key"
  aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$task"   # Chờ tối đa ~10 phút
  exit_code=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task" --query "tasks[0].containers[?name=='$key'].exitCode | [0]" --output text)
  echo "Task $key kết thúc với mã $exit_code — log: CloudWatch $(tf_out "$env" log_group), stream $key/$key/${task##*/}"
  [[ "$exit_code" == "0" ]] || die "Task $key thất bại"
}
