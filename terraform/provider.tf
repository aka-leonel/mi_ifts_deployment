terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      # Fijado en 3.74.0: desde la v4.x, aws_s3_bucket hace llamadas extra
      # (GetBucketObjectLockConfiguration, GetBucketAccelerateConfiguration)
      # que el SCP de AWS Academy deniega explícitamente y rompen el apply.
      version = "3.74.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
