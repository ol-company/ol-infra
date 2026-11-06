# ol-infra

Hạ tầng và trạng thái triển khai của OL-Platform — **mọi thay đổi môi trường đều là Pull Request vào repo này**.

```text
build-config/<env>/<module>.env   # Build-time config (không bí mật): Dockerfile nào, context, build-arg
deploy/<env>/<module>.yaml        # Trạng thái mong muốn: image digest, CPU/RAM, số task, runtime env
keycloak/realm-ol.yaml            # Cấu hình realm Keycloak dạng code
db/bootstrap.sql                  # Role + database cho mọi service (idempotent)
local/                            # Docker Compose + Caddy + ol.ps1 cho môi trường local
infrastructure/
├── bootstrap/{shared,account}    # Chạy tay một lần: state bucket, OIDC, role cho GitHub Actions
├── modules/{network,ecs-service,platform}
└── envs/{shared,dev,staging,prod}
scripts/                          # deploy.sh, smoke.sh, promote.sh, restore-drill.sh, validate-config.sh
loadtest/warehouse.js             # k6
.github/workflows/                # validate, deploy (+_deploy-env), rebuild, drift, restore-drill, ops
```

Luồng: service merge main → build image cho dev → PR cập nhật `deploy/dev` (tự merge) → `deploy` dev → smoke/E2E →
PR thăng cấp staging (tự merge) → `deploy` staging → PR thăng cấp prod (cần duyệt) → environment production duyệt → `deploy` prod.
Chi tiết: `ol-handbook/docs/04` → `docs/07`.
