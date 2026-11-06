#!/usr/bin/env bash
# Kiểm tra cấu hình trước khi merge: deploy/*.yaml đúng cấu trúc; build-config hợp lệ; không có bí mật.
# Dùng: scripts/validate-config.sh <đường-dẫn-validate-build-config.sh-của-build-tooling>
set -euo pipefail
validator="${1:?Cần đường dẫn validate-build-config.sh}"
fail=0
for f in deploy/*/*.yaml; do
  env=$(basename "$(dirname "$f")"); m=$(basename "$f" .yaml)
  [[ "$(yq '.module' "$f")" == "$m" ]] || { echo "$f: module phải là $m"; fail=1; }
  digest=$(yq '.image.digest' "$f")
  [[ -z "$digest" || "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "$f: digest sai định dạng"; fail=1; }
  for k in cpu memory desiredCount minCount maxCount; do
    v=$(yq ".runtime.$k" "$f"); [[ "$v" =~ ^[0-9]+$ ]] || { echo "$f: runtime.$k phải là số"; fail=1; }
  done
  # Giá trị env trong file deploy là cấu hình công khai — chặn tên biến trông như bí mật
  if yq '.runtime.env // {} | keys | .[]' "$f" | grep -Eiq 'SECRET|PASSWORD|TOKEN|PRIVATE|KEY$'; then
    echo "$f: runtime.env chứa biến giống bí mật — dùng Secrets Manager"; fail=1
  fi
  if [[ "$env" == "prod" ]]; then
    [[ "$(yq '.runtime.minCount' "$f")" -ge 2 || "$m" == "keycloak-config" ]] || { echo "$f: prod cần minCount ≥ 2 (chịu lỗi 1 AZ)"; fail=1; }
  fi
done
for f in build-config/*/*.env; do
  bash "$validator" "$f" >/dev/null || { echo "$f: build-config không hợp lệ"; fail=1; }
done
[[ $fail -eq 0 ]] && echo "Cấu hình hợp lệ"
exit $fail
