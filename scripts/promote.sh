#!/usr/bin/env bash
# =============================================================================
# Thăng cấp image từ môi trường <from> sang <to> bằng Pull Request.
#   scripts/promote.sh dev staging   |   scripts/promote.sh staging prod
# - Build-config của module giống nhau giữa 2 môi trường → copy NGUYÊN digest (artifact đã test)
# - Khác nhau (build-time config riêng) → kích hoạt rebuild.yml để build image cho <to>
# - staging: PR tự merge khi check xanh; prod: chờ CODEOWNERS duyệt
# Cần: GH_TOKEN (GitHub App, contents+pull-requests write trên ol-infra), yq, gh
# =============================================================================
set -euo pipefail
from="${1:?}"; to="${2:?}"
branch="bot/promote-$from-to-$to-$(date +%Y%m%d%H%M%S)"
git switch -c "$branch"
changed=()
for f in deploy/"$from"/*.yaml; do
  m=$(basename "$f" .yaml)
  digest=$(yq '.image.digest' "$f")
  [[ -n "$digest" && "$digest" != "null" ]] || continue
  [[ "$digest" == "$(yq '.image.digest' "deploy/$to/$m.yaml")" ]] && continue
  # So sánh build-config (bỏ chú thích và dòng trống)
  if diff <(grep -Ev '^\s*(#|$)' "build-config/$from/$m.env") <(grep -Ev '^\s*(#|$)' "build-config/$to/$m.env") >/dev/null; then
    export DIGEST="$digest"
    export SRC_REPO=$(yq '.source.repository' "$f") SRC_REV=$(yq '.source.revision' "$f") SRC_VER=$(yq '.source.version' "$f")
    export CFG_REV=$(yq '.source.configRevision' "$f") TOOL_REV=$(yq '.source.toolingRevision' "$f")
    yq -i '.image.digest = strenv(DIGEST) | .source.repository = strenv(SRC_REPO) | .source.revision = strenv(SRC_REV) |
           .source.version = strenv(SRC_VER) | .source.configRevision = strenv(CFG_REV) | .source.toolingRevision = strenv(TOOL_REV)' "deploy/$to/$m.yaml"
    changed+=("$m")
  else
    echo "$m: build-config $from ≠ $to → build lại cho $to"
    gh workflow run rebuild.yml -f env="$to" -f module="$m"
  fi
done

if [[ ${#changed[@]} -eq 0 ]]; then echo "Không có module cần thăng cấp bằng digest"; exit 0; fi
git config user.name "ol-automation[bot]"
git config user.email "ol-automation[bot]@users.noreply.github.com"
git add "deploy/$to"
git commit -q -m "deploy($to): thăng cấp từ $from — ${changed[*]}"
git push -q origin "$branch"
url=$(gh pr create --base main --head "$branch" --title "deploy($to): thăng cấp từ $from" \
  --body "Thăng cấp nguyên digest đã kiểm thử ở **$from** sang **$to**: ${changed[*]}. Smoke test $from đã đạt.")
echo "PR: $url"
[[ "$to" != "prod" ]] && gh pr merge "$url" --auto --squash
exit 0
