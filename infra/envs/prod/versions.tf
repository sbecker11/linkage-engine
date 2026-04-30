terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Populated after running infra/bootstrap — copy the backend_config output here.
  backend "s3" {
    bucket         = "linkage-engine-tfstate"
    key            = "prod/terraform.tfstate"
    region         = "us-west-1"
    dynamodb_table = "linkage-engine-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}
