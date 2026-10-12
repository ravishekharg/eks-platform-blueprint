# Remote state per environment, encrypted, with S3-native locking (Terraform >= 1.10).
# The bucket is created once by hand or by a bootstrap stack, with versioning on so a bad
# state write can be rolled back. CI validates with `terraform init -backend=false`.
terraform {
  backend "s3" {
    bucket       = "CHANGE-ME-tfstate"
    key          = "eks-platform-blueprint/prod/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
