# Application Load Balancer: kết thúc TLS, định tuyến theo host/path, chặn đường dẫn quản trị Keycloak.
data "aws_elb_service_account" "this" {}

resource "aws_s3_bucket" "alb_logs" {
  bucket_prefix = "${local.name}-alb-logs-"
  force_destroy = var.env != "prod" # Môi trường thử nghiệm được xóa kèm log
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # ALB access log chỉ hỗ trợ SSE-S3
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.env == "prod" ? 90 : 14
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.this.arn }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/*"
    }]
  })
}

resource "aws_lb" "this" {
  name                       = local.name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = module.network.public_subnet_ids
  security_groups            = [module.network.alb_sg_id]
  drop_invalid_header_fields = true # Chống request smuggling qua header lỗi
  idle_timeout               = 60
  enable_deletion_protection = var.deletion_protection
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # Chỉ TLS 1.2/1.3
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

locals {
  target_groups = {
    web      = { port = 8080, health_port = "traffic-port", health_path = "/health" }
    bff      = { port = 3000, health_port = "traffic-port", health_path = "/health/ready" }
    keycloak = { port = 8080, health_port = "9000", health_path = "/health/ready" }
  }
}

resource "aws_lb_target_group" "this" {
  for_each             = local.target_groups
  name                 = "${local.name}-${each.key}"
  port                 = each.value.port
  protocol             = "HTTP"
  target_type          = "ip" # Fargate awsvpc: đăng ký theo IP của task
  vpc_id               = module.network.vpc_id
  deregistration_delay = 30 # Cho request đang chạy 30 giây hoàn tất khi task bị rút
  health_check {
    path                = each.value.health_path
    port                = each.value.health_port
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# --- Keycloak: chặn console quản trị và realm master từ Internet ---
resource "aws_lb_listener_rule" "kc_admin_allow" {
  count        = length(var.keycloak_admin_cidrs) > 0 ? 1 : 0
  listener_arn = aws_lb_listener.https.arn
  priority     = 4
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["keycloak"].arn
  }
  condition {
    host_header { values = [local.id_host] }
  }
  condition {
    path_pattern { values = ["/admin*", "/realms/master*"] }
  }
  condition {
    source_ip { values = var.keycloak_admin_cidrs }
  }
}

resource "aws_lb_listener_rule" "kc_admin_block" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 5
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
  condition {
    host_header { values = [local.id_host] }
  }
  condition {
    path_pattern { values = ["/admin*", "/realms/master*"] }
  }
}

resource "aws_lb_listener_rule" "keycloak" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["keycloak"].arn
  }
  condition {
    host_header { values = [local.id_host] }
  }
}

resource "aws_lb_listener_rule" "bff" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["bff"].arn
  }
  condition {
    host_header { values = [local.app_host] }
  }
  condition {
    path_pattern { values = ["/api/*", "/auth/*", "/health/*"] }
  }
}

resource "aws_lb_listener_rule" "web" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 30
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["web"].arn
  }
  condition {
    host_header { values = [local.app_host] }
  }
}
