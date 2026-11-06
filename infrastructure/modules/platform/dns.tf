# Hosted zone nằm ở account shared → mọi bản ghi DNS tạo qua provider aws.dns (assume role sang shared)
data "aws_route53_zone" "root" {
  provider = aws.dns
  name     = var.root_domain
}

# Chứng chỉ TLS miễn phí, tự gia hạn, gắn vào ALB
resource "aws_acm_certificate" "this" {
  domain_name               = local.app_host
  subject_alternative_names = [local.id_host]
  validation_method         = "DNS"
  lifecycle {
    create_before_destroy = true # Đổi chứng chỉ không gây gián đoạn
  }
}

resource "aws_route53_record" "cert_validation" {
  provider = aws.dns
  for_each = {
    for o in aws_acm_certificate.this.domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  }
  zone_id         = data.aws_route53_zone.root.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# app.<env>.<domain> và id.<env>.<domain> trỏ vào ALB
resource "aws_route53_record" "hosts" {
  provider = aws.dns
  for_each = toset([local.app_host, local.id_host])
  zone_id  = data.aws_route53_zone.root.zone_id
  name     = each.value
  type     = "A"
  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
