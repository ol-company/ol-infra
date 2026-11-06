#!/usr/bin/env bash
# Smoke test sau triển khai — kiểm nhanh mọi thành phần trả lời đúng qua Internet.
#   scripts/smoke.sh <app_url> <id_url>
set -euo pipefail
app="${1:?app url}"; id="${2:?id url}"
fail=0
check() { # mô tả, URL, mã mong đợi
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$2" || echo 000)
  if [[ "$code" == "$3" ]]; then echo "[OK]  $1 ($code)"; else echo "[LỖI] $1: nhận $code, mong đợi $3"; fail=1; fi
}
for i in $(seq 1 20); do  # Chờ DNS/ALB sẵn sàng sau lần deploy đầu (tối đa ~5 phút)
  curl -s -o /dev/null --max-time 10 "$app/health/ready" && break
  sleep 15
done
check "BFF readiness"                 "$app/health/ready" 200
check "Frontend"                      "$app/" 200
check "Runtime config"                "$app/config.json" 200
check "API chưa đăng nhập bị chặn"    "$app/api/iam/v1/me" 401
check "Không truy cập /internal"      "$app/api/iam/internal/v1/authorize" 401
check "OIDC discovery"                "$id/realms/ol/.well-known/openid-configuration" 200
check "Admin Keycloak bị chặn"        "$id/admin/" 403
check "Realm master bị chặn"          "$id/realms/master/" 403
check "HTTP chuyển HTTPS"             "${app/https:/http:}/" 301
exit $fail
