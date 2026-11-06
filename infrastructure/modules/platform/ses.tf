# Amazon SES gửi email (mời, xác minh, đặt lại mật khẩu) cho Keycloak qua SMTP.
# Tài khoản mới ở chế độ sandbox: chỉ gửi tới địa chỉ đã xác minh → xin "production access" khi dùng thật.
resource "aws_sesv2_email_identity" "domain" {
  email_identity = local.env_zone
}

# Easy DKIM: luôn có 3 token → 3 bản ghi CNAME
resource "aws_route53_record" "dkim" {
  provider = aws.dns
  count    = 3
  zone_id  = data.aws_route53_zone.root.zone_id
  name     = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${local.env_zone}"
  type     = "CNAME"
  ttl      = 600
  records  = ["${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_sesv2_email_identity" "recipients" {
  for_each       = toset(var.ses_verified_recipients)
  email_identity = each.value # SES gửi email xác minh tới địa chỉ này
}

# SMTP của SES cần IAM user + access key (Keycloak chỉ hỗ trợ SMTP user/password)
resource "aws_iam_user" "ses_smtp" {
  name = "${local.name}-ses-smtp"
}

resource "aws_iam_user_policy" "ses_smtp" {
  name = "send-email"
  user = aws_iam_user.ses_smtp.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ses:SendRawEmail"
      Resource = "*"
      Condition = {
        StringLike = { "ses:FromAddress" = "*@${local.env_zone}" } # Chỉ gửi từ domain của môi trường
      }
    }]
  })
}

resource "aws_iam_access_key" "ses_smtp" {
  user = aws_iam_user.ses_smtp.name
}
