# =============================================================================
# Mạng: VPC, subnet public/private trên nhiều AZ, Internet Gateway, NAT (tùy chọn), security group.
#  - public subnet : ALB; và task ECS ở môi trường tiết kiệm (không NAT) — có IP public nhưng SG chỉ cho ALB vào
#  - private subnet: RDS (luôn luôn); task ECS khi bật NAT (production)
# =============================================================================
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

variable "name" { type = string }                       # Tiền tố tên, ví dụ "ol-dev"
variable "cidr" { type = string }                       # Ví dụ "10.10.0.0/16"
variable "az_count" {
  type    = number
  default = 2
}
variable "enable_nat" {
  type        = bool
  default     = false
  description = "true: task chạy trong private subnet, ra Internet qua NAT (~32 USD/tháng/NAT + phí dữ liệu)"
}
variable "single_nat" {
  type        = bool
  default     = true
  description = "true: 1 NAT dùng chung (rẻ, mất NAT khi AZ đó lỗi); false: mỗi AZ một NAT"
}
variable "app_ports" {
  type    = list(number)
  default = [3000, 8080, 9000]
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true   # Cần cho Service Connect / Cloud Map và RDS endpoint
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

# /16 chia thành /20: public dùng chỉ số 0..n-1, private dùng 8..8+n-1
resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.cidr, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false # Chỉ task nào được chỉ định assign_public_ip mới có IP public
  tags                    = { Name = "${var.name}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr, 4, count.index + 8)
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.name}-private-${local.azs[count.index]}", Tier = "private" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

locals {
  nat_count = var.enable_nat ? (var.single_nat ? 1 : var.az_count) : 0
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.name}-nat-${count.index}" }
  depends_on    = [aws_internet_gateway.this]
}

# Mỗi AZ một route table private; không có NAT thì private subnet không ra được Internet (chỉ RDS nằm đây)
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  dynamic "route" {
    for_each = var.enable_nat ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[var.single_nat ? 0 : count.index].id
    }
  }
  tags = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------- Security groups (tường lửa theo vai trò) ----------------
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "ALB: nhan HTTPS tu Internet"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp" # Chỉ để chuyển hướng sang HTTPS
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  for_each                     = toset([for p in var.app_ports : tostring(p)])
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "Task ECS: chi nhan tu ALB va tu chinh nhom app"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  for_each                     = toset([for p in var.app_ports : tostring(p)])
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  ip_protocol                  = "tcp"
}

# Service gọi nhau nội bộ (Service Connect) + cụm Keycloak (JGroups 7800, 57800)
resource "aws_vpc_security_group_ingress_rule" "app_from_app" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0" # Cần tới ECR, Secrets Manager, Keycloak public URL, SES
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "RDS: chi nhan PostgreSQL tu task ECS"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

output "vpc_id" { value = aws_vpc.this.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "alb_sg_id" { value = aws_security_group.alb.id }
output "app_sg_id" { value = aws_security_group.app.id }
output "db_sg_id" { value = aws_security_group.db.id }
# Subnet cho task ECS: private khi có NAT, public khi không
output "task_subnet_ids" { value = var.enable_nat ? aws_subnet.private[*].id : aws_subnet.public[*].id }
output "task_public_ip" { value = !var.enable_nat }
