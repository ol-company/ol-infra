module "network" {
  source     = "../network"
  name       = local.name
  cidr       = var.vpc_cidr
  az_count   = var.az_count
  enable_nat = var.enable_nat
  single_nat = var.single_nat
}
