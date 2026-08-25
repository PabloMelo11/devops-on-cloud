terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.92"
    }
  }

  required_version = ">= 1.2"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }

  assume_role {
    role_arn     = var.assume_role.role_arn
    session_name = var.assume_role.session_name
    external_id  = var.assume_role.external_id
  }
}
