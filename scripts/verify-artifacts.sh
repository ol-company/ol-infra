#!/usr/bin/env bash
# Kiểm chứng ARTIFACT trước khi triển khai: mọi image trong deploy/<env> phải
#  (1) tồn tại trong ECR đúng digest, (2) có attestation provenance do workflow của org ký,
#  (3) được build từ ol-build-tooling (Dockerfile tập trung), không phải build tay.
#   scripts/verify-artifacts.sh <env>      (cần: aws đã đăng nhập, GH_TOKEN, SHARED_ACCOUNT_ID, OWNER)
set -euo pipefail
env="${1:?}"
registry="${SHARED_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$registry" >/dev/null
fail=0
for f in deploy/"$env"/*.yaml; do
  m=$(basename "$f" .yaml)
  digest=$(yq '.image.digest' "$f")
  [[ -n "$digest" && "$digest" != "null" ]] || { echo "[--] $m: chưa có image"; continue; }
  ref="$registry/ol/$m@$digest"
  if gh attestation verify "oci://$ref" --owner "$OWNER" \
       --signer-workflow "$OWNER/ol-build-tooling/.github/workflows/build-image.yml" >/dev/null 2>&1; then
    echo "[OK] $m $digest — provenance hợp lệ, build bởi build-image.yml"
  else
    echo "[LỖI] $m $digest — không xác minh được nguồn gốc"; fail=1
  fi
done
exit $fail
