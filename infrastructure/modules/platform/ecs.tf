# Cụm ECS, namespace Service Connect, log group, các service và task chạy một lần.
resource "aws_ecs_cluster" "this" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled" # Metric CPU/RAM/số task theo service
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

# Service gọi nhau bằng tên ngắn: http://iam-service:3000, http://keycloak:8080
resource "aws_service_discovery_http_namespace" "this" {
  name = "${local.name}.internal"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ol/${var.env}/app"
  retention_in_days = var.log_retention_days
}

locals {
  common = {
    cluster_arn                   = aws_ecs_cluster.this.arn
    cluster_name                  = aws_ecs_cluster.this.name
    subnet_ids                    = module.network.task_subnet_ids
    security_group_ids            = [module.network.app_sg_id]
    assign_public_ip              = module.network.task_public_ip
    execution_role_arn            = aws_iam_role.execution.arn
    task_role_arn                 = aws_iam_role.task.arn
    log_group_name                = aws_cloudwatch_log_group.app.name
    service_connect_namespace_arn = aws_service_discovery_http_namespace.this.arn
  }

  # Đặc tả các service chạy lâu dài
  services = {
    "iam-service" = {
      port   = 3000
      tg     = null
      server = true
      ro     = true
      adot   = var.adot_enabled
      health = local.node_health
      env = merge(local.node_common_env, {
        OTEL_SERVICE_NAME = "iam-service"
        DB_NAME           = "iam"
        DB_USER           = "iam_app"
        APP_URL           = local.app_url
      })
      secrets = {
        DB_PASSWORD       = local.secret["db/iam-app"]
        IAM_CLIENT_SECRET = local.secret["clients/ol-iam-service"]
      }
    }
    "warehouse-service" = {
      port   = 3000
      tg     = null
      server = true
      ro     = true
      adot   = var.adot_enabled
      health = local.node_health
      env = merge(local.node_common_env, {
        OTEL_SERVICE_NAME = "warehouse-service"
        DB_NAME           = "warehouse"
        DB_USER           = "warehouse_app"
        IAM_INTERNAL_URL  = "http://iam-service:3000"
      })
      secrets = {
        DB_PASSWORD             = local.secret["db/warehouse-app"]
        WAREHOUSE_CLIENT_SECRET = local.secret["clients/ol-warehouse-service"]
      }
    }
    "bff" = {
      port   = 3000
      tg     = aws_lb_target_group.this["bff"].arn
      server = true # Keycloak gọi back-channel logout tới http://bff:3000
      ro     = true
      adot   = var.adot_enabled
      health = local.node_health
      env = merge(local.node_common_env, {
        OTEL_SERVICE_NAME      = "bff"
        DB_NAME                = "bff"
        DB_USER                = "bff_app"
        APP_URL                = local.app_url
        IAM_INTERNAL_URL       = "http://iam-service:3000"
        WAREHOUSE_INTERNAL_URL = "http://warehouse-service:3000"
      })
      secrets = {
        DB_PASSWORD        = local.secret["db/bff-app"]
        OIDC_CLIENT_SECRET = local.secret["clients/ol-bff"]
        SESSION_ENC_KEY    = local.secret["bff/session-key"]
      }
    }
    "web-admin" = {
      port    = 8080
      tg      = aws_lb_target_group.this["web"].arn
      server  = false
      ro      = true
      adot    = false
      health  = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1"]
      env     = { APP_ENV = var.env }
      secrets = {}
    }
    "keycloak" = {
      port   = 8080
      tg     = aws_lb_target_group.this["keycloak"].arn
      server = true
      ro     = false # Keycloak ghi vào /opt/keycloak/data
      adot   = false
      health = ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/9000 && printf 'GET /health/ready HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n' >&3 && grep -q 'HTTP/1.1 200' <&3"]
      env = {
        KC_DB_URL                       = "jdbc:postgresql://${aws_db_instance.this.address}:5432/keycloak?sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-global-bundle.pem"
        KC_DB_USERNAME                  = "keycloak"
        KC_HOSTNAME                     = "https://${local.id_host}"
        KC_HOSTNAME_BACKCHANNEL_DYNAMIC = "true"
        KC_HTTP_ENABLED                 = "true" # TLS kết thúc ở ALB; mạng nội bộ dùng HTTP
        KC_PROXY_HEADERS                = "xforwarded"
        KC_BOOTSTRAP_ADMIN_USERNAME     = "admin"
        JAVA_OPTS_KC_HEAP               = "-XX:MaxRAMPercentage=70"
      }
      secrets = {
        KC_DB_PASSWORD              = local.secret["db/keycloak"]
        KC_BOOTSTRAP_ADMIN_PASSWORD = local.secret["keycloak/admin"]
      }
    }
  }

  # Task chạy một lần (migration, khởi tạo DB, cấu hình realm, CLI quản trị)
  tasks = merge(
    { for m in ["iam-service", "warehouse-service", "bff"] : "${m}-migrate" => {
      image   = try(local.image[m], null)
      command = ["node", "--enable-source-maps", "dist/migrate.js"]
      env = merge(local.node_common_env, {
        DB_NAME = { "iam-service" = "iam", "warehouse-service" = "warehouse", "bff" = "bff" }[m]
        DB_USER = { "iam-service" = "iam_migrator", "warehouse-service" = "warehouse_migrator", "bff" = "bff_migrator" }[m]
      })
      secrets = { DB_PASSWORD = local.secret[{ "iam-service" = "db/iam-migrator", "warehouse-service" = "db/warehouse-migrator", "bff" = "db/bff-migrator" }[m]] }
    } },
    {
      "iam-cli" = {
        image   = try(local.image["iam-service"], null)
        command = ["node", "--enable-source-maps", "dist/cli.js"]
        env     = merge(local.services["iam-service"].env, { OTEL_SERVICE_NAME = "iam-cli" })
        secrets = local.services["iam-service"].secrets
      }
      "keycloak-config" = {
        image   = try(local.image["keycloak-config"], null)
        command = null
        env = {
          KEYCLOAK_URL                       = "http://keycloak:8080" # Script deploy ghi đè bằng IP task Keycloak
          KEYCLOAK_USER                      = "admin"
          KEYCLOAK_AVAILABILITYCHECK_ENABLED = "true"
          APP_URL                            = local.app_url
          BFF_BACKCHANNEL_LOGOUT_URL         = "http://bff:3000/auth/backchannel-logout"
          SMTP_HOST                          = "email-smtp.${var.region}.amazonaws.com"
          SMTP_PORT                          = "587"
          SMTP_FROM                          = "noreply@${local.env_zone}"
          SMTP_AUTH                          = "true"
          SMTP_STARTTLS                      = "true"
        }
        secrets = {
          KEYCLOAK_PASSWORD       = local.secret["keycloak/admin"]
          BFF_CLIENT_SECRET       = local.secret["clients/ol-bff"]
          IAM_CLIENT_SECRET       = local.secret["clients/ol-iam-service"]
          WAREHOUSE_CLIENT_SECRET = local.secret["clients/ol-warehouse-service"]
          SMTP_USER               = "${local.secret["ses/smtp"]}:username::"
          SMTP_PASSWORD           = "${local.secret["ses/smtp"]}:password::"
        }
      }
      "db-init" = {
        image = "public.ecr.aws/docker/library/postgres:${var.rds_engine_major}-alpine"
        command = ["sh", "-c", join(" && ", [
          "wget -qO /tmp/rds.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem", # CA để xác minh chứng chỉ RDS
          "printf '%s' \"$BOOTSTRAP_SQL\" > /tmp/bootstrap.sql",
          "psql -v keycloak_password=\"$KC_PW\" -v iam_app_password=\"$IAM_APP_PW\" -v iam_migrator_password=\"$IAM_MIG_PW\" -v warehouse_app_password=\"$WH_APP_PW\" -v warehouse_migrator_password=\"$WH_MIG_PW\" -v bff_app_password=\"$BFF_APP_PW\" -v bff_migrator_password=\"$BFF_MIG_PW\" -f /tmp/bootstrap.sql",
        ])]
        env = {
          BOOTSTRAP_SQL = var.db_bootstrap_sql
          PGHOST        = aws_db_instance.this.address
          PGDATABASE    = "postgres"
          PGSSLMODE     = "verify-full"
          PGSSLROOTCERT = "/tmp/rds.pem"
        }
        secrets = {
          PGUSER     = "${local.rds_master_secret}:username::"
          PGPASSWORD = "${local.rds_master_secret}:password::"
          KC_PW      = local.secret["db/keycloak"]
          IAM_APP_PW = local.secret["db/iam-app"]
          IAM_MIG_PW = local.secret["db/iam-migrator"]
          WH_APP_PW  = local.secret["db/warehouse-app"]
          WH_MIG_PW  = local.secret["db/warehouse-migrator"]
          BFF_APP_PW = local.secret["db/bff-app"]
          BFF_MIG_PW = local.secret["db/bff-migrator"]
        }
      }
    },
  )
}

module "service" {
  source   = "../ecs-service"
  for_each = { for k, v in local.services : k => v if contains(keys(local.image), k) } # Chỉ module đã có image

  name                          = each.key
  family                        = "${local.name}-${each.key}"
  region                        = var.region
  image                         = local.image[each.key]
  cpu                           = local.runtime[each.key].cpu
  memory                        = local.runtime[each.key].memory
  desired_count                 = local.runtime[each.key].desiredCount
  min_count                     = local.runtime[each.key].minCount
  max_count                     = local.runtime[each.key].maxCount
  environment                   = merge(each.value.env, { for k, v in try(local.runtime[each.key].env, {}) : k => tostring(v) }, { SECRETS_ROTATION = local.secrets_rotation })
  secrets                       = each.value.secrets
  container_port                = each.value.port
  target_group_arn              = each.value.tg
  service_connect_server        = each.value.server
  readonly_root                 = each.value.ro
  adot_sidecar                  = each.value.adot
  health_check_command          = each.value.health
  use_spot                      = var.use_spot
  office_hours                  = var.office_hours_only
  cluster_arn                   = local.common.cluster_arn
  cluster_name                  = local.common.cluster_name
  subnet_ids                    = local.common.subnet_ids
  security_group_ids            = local.common.security_group_ids
  assign_public_ip              = local.common.assign_public_ip
  execution_role_arn            = local.common.execution_role_arn
  task_role_arn                 = local.common.task_role_arn
  log_group_name                = local.common.log_group_name
  service_connect_namespace_arn = local.common.service_connect_namespace_arn

  depends_on = [aws_ecs_cluster_capacity_providers.this, aws_lb_listener.https]
}

module "task" {
  source   = "../ecs-service"
  for_each = { for k, v in local.tasks : k => v if v.image != null }

  name               = each.key
  family             = "${local.name}-${each.key}"
  region             = var.region
  image              = each.value.image
  cpu                = 256
  memory             = 512
  command            = each.value.command
  environment        = each.value.env
  secrets            = each.value.secrets
  readonly_root      = false
  create_service     = false
  cluster_arn        = local.common.cluster_arn
  cluster_name       = local.common.cluster_name
  subnet_ids         = local.common.subnet_ids
  security_group_ids = local.common.security_group_ids
  execution_role_arn = local.common.execution_role_arn
  task_role_arn      = local.common.task_role_arn
  log_group_name     = local.common.log_group_name
}
