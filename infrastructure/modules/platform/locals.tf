locals {
  name     = "ol-${var.env}"
  env_zone = var.env == "prod" ? var.root_domain : "${var.env}.${var.root_domain}"
  app_host = "app.${local.env_zone}"
  id_host  = "id.${local.env_zone}"
  app_url  = "https://${local.app_host}"
  issuer   = "https://${local.id_host}/realms/ol"
  registry = "${var.shared_account_id}.dkr.ecr.${var.region}.amazonaws.com"

  # Module nào đã có image (digest khác rỗng) mới được triển khai
  image = {
    for m, d in var.deploy : m => "${local.registry}/ol/${m}@${d.image.digest}"
    if try(d.image.digest, "") != ""
  }
  runtime = { for m, d in var.deploy : m => d.runtime }

  rds_ca = "/etc/ssl/certs/rds-global-bundle.pem"

  # Biến môi trường chung của mọi service Node
  node_common_env = {
    APP_ENV               = var.env
    PORT                  = "3000"
    DB_HOST               = aws_db_instance.this.address
    DB_PORT               = "5432"
    DB_SSL                = "true"
    DB_SSL_CA_FILE        = local.rds_ca
    OIDC_ISSUER           = local.issuer
    OIDC_INTERNAL_ISSUER  = "http://keycloak:8080/realms/ol"
    KEYCLOAK_INTERNAL_URL = "http://keycloak:8080"
  }

  node_health = ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/health/live').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
}
