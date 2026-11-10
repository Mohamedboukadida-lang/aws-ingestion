provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project = var.project
      env     = var.env
      managed = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
