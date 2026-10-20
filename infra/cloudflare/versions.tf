terraform {
  required_version = ">= 1.10"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.27"
    }
  }

  # State lives in a private Backblaze B2 bucket via B2's S3-compatible API.
  # Bucket/endpoint come from backend.hcl (see backend.hcl.example); B2
  # credentials from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
  backend "s3" {}
}
