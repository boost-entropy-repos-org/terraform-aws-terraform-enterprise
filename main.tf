terraform {
  required_version = ">= 0.13"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1.0"
    }
    template = {
      source  = "hashicorp/template"
      version = "~> 2.1.2"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 3.0.0"
    }
  }
}

data "aws_region" "current" {}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_kms_key" "tfe_key" {
  deletion_window_in_days = var.kms_key_deletion_window
  description             = "AWS KMS Customer-managed key to encrypt TFE and other resources"
  enable_key_rotation     = false
  is_enabled              = true
  key_usage               = "ENCRYPT_DECRYPT"

  tags = merge(
    { Name = "${var.friendly_name_prefix}-tfe-kms-key" },
    var.common_tags,
  )
}

resource "aws_kms_alias" "key_alias" {
  name          = "alias/${var.kms_key_alias}"
  target_key_id = aws_kms_key.tfe_key.key_id
}

locals {
  active_active                       = var.node_count >= 2
  ami_id                              = local.default_ami_id ? data.aws_ami.ubuntu.id : var.ami_id
  aws_lb_target_group_tfe_tg_8800_arn = local.active_active ? "" : module.load_balancer.aws_lb_target_group_tfe_tg_8800_arn
  default_ami_id                      = var.ami_id == ""
  fqdn                                = "${var.tfe_subdomain}.${var.domain_name}"
}

module "object_storage" {
  source = "./modules/object_storage"

  friendly_name_prefix       = var.friendly_name_prefix
  kms_key_arn                = aws_kms_key.tfe_key.arn
  tfe_license_filepath       = var.tfe_license_filepath
  tfe_license_name           = var.tfe_license_name
  proxy_cert_bundle_filepath = var.proxy_cert_bundle_filepath
  proxy_cert_bundle_name     = var.proxy_cert_bundle_name

  common_tags = var.common_tags
}

module "service_accounts" {
  source = "./modules/service_accounts"

  aws_bucket_bootstrap_arn = module.object_storage.s3_bucket_bootstrap_arn
  aws_bucket_data_arn      = module.object_storage.s3_bucket_data_arn
  friendly_name_prefix     = var.friendly_name_prefix
  kms_key_arn              = aws_kms_key.tfe_key.arn

  common_tags = var.common_tags
}

module "secrets_manager" {
  source = "./modules/secrets_manager"

  friendly_name_prefix  = var.friendly_name_prefix
  deploy_secretsmanager = var.deploy_secretsmanager

  common_tags = var.common_tags
}

module "networking" {
  source = "./modules/networking"

  deploy_vpc                   = var.deploy_vpc
  friendly_name_prefix         = var.friendly_name_prefix
  network_cidr                 = var.network_cidr
  network_private_subnet_cidrs = var.network_private_subnet_cidrs
  network_public_subnet_cidrs  = var.network_public_subnet_cidrs

  common_tags = var.common_tags
}

locals {
  bastion_host_subnet     = var.deploy_vpc ? module.networking.bastion_host_subnet : var.bastion_host_subnet
  network_id              = var.deploy_vpc ? module.networking.network_id : var.network_id
  network_private_subnets = var.deploy_vpc ? module.networking.network_private_subnets : var.network_private_subnets
  network_public_subnets  = var.deploy_vpc ? module.networking.network_public_subnets : var.network_public_subnets
}

module "redis" {
  source = "./modules/redis"

  active_active                = local.active_active
  friendly_name_prefix         = var.friendly_name_prefix
  network_id                   = local.network_id
  network_private_subnet_cidrs = var.network_private_subnet_cidrs
  network_subnets_private      = local.network_private_subnets
  tfe_instance_sg              = module.vm.tfe_instance_sg

  cache_size           = var.redis_cache_size
  engine_version       = var.redis_engine_version
  parameter_group_name = var.redis_parameter_group_name

  kms_key_arn                 = aws_kms_key.tfe_key.arn
  redis_encryption_in_transit = var.redis_encryption_in_transit
  redis_encryption_at_rest    = var.redis_encryption_at_rest
  redis_require_password      = var.redis_require_password

  common_tags = var.common_tags
}

module "database" {
  source = "./modules/database"

  db_size                      = var.db_size
  engine_version               = var.postgres_engine_version
  friendly_name_prefix         = var.friendly_name_prefix
  network_id                   = local.network_id
  network_private_subnet_cidrs = var.network_private_subnet_cidrs
  network_subnets_private      = local.network_private_subnets
  tfe_instance_sg              = module.vm.tfe_instance_sg

  common_tags = var.common_tags
}

module "bastion" {
  source = "./modules/bastion"

  ami_id                     = local.ami_id
  bastion_host_subnet        = local.bastion_host_subnet
  bastion_ingress_cidr_allow = var.bastion_ingress_cidr_allow
  bastion_keypair            = var.bastion_keypair
  deploy_bastion             = var.deploy_bastion
  deploy_vpc                 = var.deploy_vpc
  friendly_name_prefix       = var.friendly_name_prefix
  kms_key_id                 = aws_kms_key.tfe_key.arn
  network_id                 = local.network_id
  userdata_script            = module.user_data.bastion_userdata_base64_encoded

  common_tags = var.common_tags
}

locals {
  bastion_key_private = var.deploy_bastion ? module.bastion.generated_bastion_key_private : var.bastion_key_private
  bastion_key_public  = var.deploy_bastion ? module.bastion.generated_bastion_key_public : var.bastion_key_private
  bastion_sg          = var.deploy_bastion ? module.bastion.bastion_sg : var.bastion_sg
}

module "user_data" {
  source = "./modules/user_data"

  active_active                 = local.active_active
  aws_bucket_bootstrap          = module.object_storage.s3_bucket_bootstrap
  aws_bucket_data               = module.object_storage.s3_bucket_data
  aws_region                    = data.aws_region.current.name
  fqdn                          = local.fqdn
  friendly_name_prefix          = var.friendly_name_prefix
  generated_bastion_key_private = local.bastion_key_private
  kms_key_arn                   = aws_kms_key.tfe_key.arn
  pg_dbname                     = module.database.db_name
  pg_password                   = module.database.db_password
  pg_netloc                     = module.database.db_endpoint
  pg_user                       = module.database.db_username
  proxy_cert_bundle_name        = var.proxy_cert_bundle_name
  proxy_ip                      = var.proxy_ip
  no_proxy                      = var.no_proxy
  redis_host                    = module.redis.redis_endpoint
  redis_pass                    = module.redis.redis_password
  redis_port                    = module.redis.redis_port
  redis_use_password_auth       = module.redis.redis_use_password_auth
  redis_use_tls                 = module.redis.redis_transit_encryption_enabled
  tfe_license                   = var.tfe_license_name
}

module "load_balancer" {
  source = "./modules/load_balancer"

  active_active                  = local.active_active
  admin_dashboard_ingress_ranges = var.admin_dashboard_ingress_ranges
  certificate_arn                = var.acm_certificate_arn
  domain_name                    = var.domain_name
  friendly_name_prefix           = var.friendly_name_prefix
  fqdn                           = local.fqdn
  load_balancing_scheme          = var.load_balancing_scheme
  network_id                     = local.network_id
  network_public_subnets         = local.network_public_subnets
  ssl_policy                     = var.ssl_policy

  common_tags = var.common_tags
}

module "vm" {
  source = "./modules/vm"

  active_active                       = local.active_active
  aws_iam_instance_profile            = module.service_accounts.aws_iam_instance_profile
  ami_id                              = local.ami_id
  aws_lb                              = module.load_balancer.aws_lb_security_group
  aws_lb_target_group_tfe_tg_443_arn  = module.load_balancer.aws_lb_target_group_tfe_tg_443_arn
  aws_lb_target_group_tfe_tg_8800_arn = module.load_balancer.aws_lb_target_group_tfe_tg_8800_arn
  bastion_key                         = local.bastion_key_public
  bastion_sg                          = local.bastion_sg
  default_ami_id                      = local.default_ami_id
  friendly_name_prefix                = var.friendly_name_prefix
  instance_type                       = var.instance_type
  network_id                          = local.network_id
  network_subnets_private             = local.network_private_subnets
  node_count                          = var.node_count
  userdata_script                     = module.user_data.tfe_userdata_base64_encoded
}
