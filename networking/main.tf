terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.92"
    }
  }

  backend "s3" {
    bucket         = "nsse-terraform-state-files-2026"
    key            = "networking/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "nsse-terraform-state-locking"
  }

  required_version = ">= 1.2"
}

provider "aws" {
  region = var.region

  assume_role {
    role_arn     = var.assume_role.role_arn
    session_name = var.assume_role.session_name
    external_id  = var.assume_role.external_id
  }
}
