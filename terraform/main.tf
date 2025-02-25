terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.84"
    }
  }

  backend "s3" {
    bucket         = "hummingbird-terraform-state-bucket"
    key            = "hummingbird/terraform.tfstate"
    dynamodb_table = "hummingbird-terraform-state-lock-table"
    encrypt        = true
  }
}

locals {
  common_tags = {
    Scope = "mscs"
    App   = "hummingbird"
    Class = "CS7990"
  }
}

module "networking" {
  source               = "./modules/networking"
  additional_tags      = local.common_tags
  vpc_cidr             = "10.0.0.0/24"
  public_subnet_cidrs  = ["10.0.0.0/26", "10.0.0.64/26"]
  private_subnet_cidrs = ["10.0.0.128/26", "10.0.0.192/26"]
}

module "media_bucket" {
  source               = "./modules/media-bucket"
  additional_tags      = local.common_tags
  media_s3_bucket_name = var.media_s3_bucket_name
}

module "ecr" {
  source                               = "./modules/ecr"
  additional_tags                      = local.common_tags
  aws_region                           = var.aws_region
  hummingbird_app_docker_build_context = "../hummingbird/app"
}

module "cloudwatch" {
  source          = "./modules/cloudwatch"
  additional_tags = local.common_tags
}

module "dynamodb" {
  depends_on = [module.networking]

  source                  = "./modules/dynamodb"
  additional_tags         = local.common_tags
  aws_region              = var.aws_region
  vpc_id                  = module.networking.vpc_id
  dynamodb_table_name     = var.media_dymamo_table_name
  private_route_table_ids = module.networking.private_route_table_ids
}

module "eventing" {
  depends_on = [module.ecr]

  source          = "./modules/eventing"
  additional_tags = local.common_tags
}

module "app" {
  depends_on = [
    module.cloudwatch,
    module.dynamodb,
    module.ecr,
    module.media_bucket,
    module.networking
  ]

  source                     = "./modules/app"
  additional_tags            = local.common_tags
  app_port                   = var.hummingbird_app_port
  aws_region                 = var.aws_region
  dynamodb_table_arn         = module.dynamodb.dynamodb_table_arn
  dynamodb_table_name        = module.dynamodb.dynamodb_table_name
  ecr_repository_arn         = module.ecr.ecr_repository_arn
  image_uri                  = module.ecr.image_uri
  media_bucket_arn           = module.media_bucket.media_bucket_arn
  media_management_topic_arn = module.eventing.media_management_topic_arn
  media_s3_bucket_name       = var.media_s3_bucket_name
  node_env                   = var.node_env
  private_subnet_ids         = module.networking.private_subnet_ids
  public_subnet_ids          = module.networking.public_subnet_ids
  vpc_id                     = module.networking.vpc_id
}

module "lambdas" {
  depends_on = [
    module.dynamodb,
    module.media_bucket
  ]

  source                              = "./modules/lambda"
  additional_tags                     = local.common_tags
  dynamodb_table_arn                  = module.dynamodb.dynamodb_table_arn
  dynamodb_table_name                 = module.dynamodb.dynamodb_table_name
  lambdas_src_path                    = "../hummingbird/lambdas"
  media_bucket_arn                    = module.media_bucket.media_bucket_arn
  media_bucket_id                     = module.media_bucket.media_bucket_id
  media_management_sqs_queue_arn      = module.eventing.media_management_sqs_queue_arn
  media_s3_bucket_name                = var.media_s3_bucket_name
  opentelemetry_collector_config_file = var.lambda_opentelemetry_collector_config_file
}
