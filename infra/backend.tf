# The bucket name contains the account ID, so it is passed at init time:
#   terraform init -backend-config=backend.hcl
# backend.hcl is gitignored; see backend.hcl.example.
terraform {
  backend "s3" {
    key          = "infra/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
