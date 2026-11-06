#!/usr/bin/env bash
# =============================================================================
# DIỄN TẬP KHÔI PHỤC: khôi phục RDS về thời điểm gần nhất sang instance TẠM, kiểm tra dữ liệu, rồi xóa.
# Đo thời gian khôi phục thực tế (RTO) và độ mới dữ liệu (RPO). Không đụng vào instance đang chạy.
#   scripts/restore-drill.sh <env>
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib.sh"
env="${1:?}"
terraform -chdir="infrastructure/envs/$env" init -input=false -backend-config=backend.hcl >/dev/null
src=$(tf_out "$env" rds_identifier)
target="$src-drill-$(date +%Y%m%d%H%M)"
subnet_group=$(tf_out "$env" rds_subnet_group)
sg=$(tf_out "$env" db_security_group_id)
start=$(date +%s)

latest=$(aws rds describe-db-instances --db-instance-identifier "$src" --query 'DBInstances[0].LatestRestorableTime' --output text)
log "Khôi phục $src về $latest sang $target"
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier "$src" --target-db-instance-identifier "$target" \
  --use-latest-restorable-time --db-subnet-group-name "$subnet_group" --vpc-security-group-ids "$sg" \
  --db-instance-class db.t4g.micro --no-multi-az --no-publicly-accessible --tags Key=Purpose,Value=restore-drill >/dev/null
trap 'log "Dọn instance tạm"; aws rds delete-db-instance --db-instance-identifier "$target" --skip-final-snapshot --delete-automated-backups >/dev/null || true' EXIT
aws rds wait db-instance-available --db-instance-identifier "$target"
end=$(date +%s)
rpo_seconds=$(( $(date +%s) - $(date -d "$latest" +%s) ))
log "Khôi phục xong sau $(( (end-start)/60 )) phút. Độ trễ dữ liệu tại thời điểm bắt đầu ≈ $(( rpo_seconds/60 )) phút"
status=$(aws rds describe-db-instances --db-instance-identifier "$target" --query 'DBInstances[0].DBInstanceStatus' --output text)
[[ "$status" == "available" ]] || die "Instance khôi phục không ở trạng thái available"
{
  echo "### Diễn tập khôi phục $env — $(date -u +%FT%TZ)"
  echo "- Nguồn: $src, thời điểm khôi phục: $latest"
  echo "- Thời gian khôi phục (RTO đo được): $(( (end-start)/60 )) phút"
  echo "- Trạng thái: $status"
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
