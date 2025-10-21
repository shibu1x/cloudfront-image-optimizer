terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    key          = "cloudfront/terraform.tfstate"
    encrypt      = false
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}

# Lambda@Edge functions must be in us-east-1
provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}

# S3 Bucket for CloudFront Origin
resource "aws_s3_bucket" "origin" {
  bucket = var.s3_bucket_name

  tags = {
    Purpose = "CloudFront Origin Storage"
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "origin" {
  bucket = aws_s3_bucket.origin.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning disabled
resource "aws_s3_bucket_versioning" "origin" {
  bucket = aws_s3_bucket.origin.id

  versioning_configuration {
    status = "Disabled"
  }
}

# Server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "origin" {
  bucket = aws_s3_bucket.origin.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Lifecycle rules for resized images
resource "aws_s3_bucket_lifecycle_configuration" "origin" {
  bucket = aws_s3_bucket.origin.id

  # Clean up old resized images
  rule {
    id     = "cleanup-resized-images"
    status = "Enabled"

    filter {
      prefix = "resize/"
    }

    expiration {
      days = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  # Clean up incomplete multipart uploads
  rule {
    id     = "cleanup-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# CloudFront Origin Access Control
resource "aws_cloudfront_origin_access_control" "s3_origin" {
  name                              = "${var.s3_bucket_name}-oac"
  description                       = "OAC for ${var.s3_bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Viewer Request Function
module "viewer_request_function" {
  source = "./modules/lambda-edge"

  providers = {
    aws.us-east-1 = aws.us-east-1
  }

  function_name = "${var.project_name}-viewer-request"
  runtime       = "nodejs22.x"
  handler       = "index.handler"
  timeout       = 5
  memory_size   = 128
  s3_bucket_arn = aws_s3_bucket.origin.arn
  log_region    = var.aws_region

  tags = {
    FunctionType = "viewer-request"
  }
}

# Origin Response Function
module "origin_response_function" {
  source = "./modules/lambda-edge"

  providers = {
    aws.us-east-1 = aws.us-east-1
  }

  function_name = "${var.project_name}-origin-response"
  runtime       = "nodejs22.x"
  handler       = "index.handler"
  timeout       = 5
  memory_size   = 128
  s3_bucket_arn = aws_s3_bucket.origin.arn
  log_region    = var.aws_region

  tags = {
    FunctionType = "origin-response"
  }
}

# S3 bucket policy to allow Lambda@Edge access
resource "aws_s3_bucket_policy" "lambda_access" {
  bucket = aws_s3_bucket.origin.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.origin.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.main.arn
          }
        }
      },
      {
        Sid    = "AllowLambdaEdgeWrite"
        Effect = "Allow"
        Principal = {
          AWS = [
            module.viewer_request_function.role_arn,
            module.origin_response_function.role_arn
          ]
        }
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        Resource = "${aws_s3_bucket.origin.arn}/resize/*"
      },
      {
        Sid    = "AllowLambdaEdgeRead"
        Effect = "Allow"
        Principal = {
          AWS = [
            module.viewer_request_function.role_arn,
            module.origin_response_function.role_arn
          ]
        }
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.origin.arn}/origin/*"
      }
    ]
  })
}

# GitHub Actions OIDC Provider (must exist in AWS account)
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = {
    Purpose = "GitHub Actions Deployment"
  }
}

# Policy for Lambda function updates
resource "aws_iam_role_policy" "lambda_update" {
  name = "lambda-update-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:PublishVersion",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:DeleteFunction",
          "lambda:EnableReplication*"
        ]
        Resource = [
          module.viewer_request_function.function_arn,
          module.origin_response_function.function_arn,
          "${module.viewer_request_function.function_arn}:*",
          "${module.origin_response_function.function_arn}:*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:ListFunctions",
          "lambda:ListVersionsByFunction"
        ]
        Resource = "*"
      }
    ]
  })
}

# Policy for CloudFront management
resource "aws_iam_role_policy" "cloudfront_management" {
  name = "cloudfront-management-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudfront:GetDistribution",
          "cloudfront:GetDistributionConfig",
          "cloudfront:ListDistributions",
          "cloudfront:UpdateDistribution"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudfront:CreateInvalidation",
          "cloudfront:GetInvalidation",
          "cloudfront:ListInvalidations"
        ]
        Resource = "*"
      }
    ]
  })
}

# CloudFront distribution
resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  wait_for_deployment = false
  price_class         = "PriceClass_200"
  comment             = "${var.project_name} distribution"

  # S3 Origin with OAC
  origin {
    domain_name              = aws_s3_bucket.origin.bucket_regional_domain_name
    origin_id                = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_origin.id
    origin_path              = "/origin"
  }

  default_cache_behavior {
    target_origin_id       = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id          = aws_cloudfront_cache_policy.optimized.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.custom.id

    # Attach Lambda@Edge functions
    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = module.viewer_request_function.qualified_arn
      include_body = false
    }

    lambda_function_association {
      event_type   = "origin-response"
      lambda_arn   = module.origin_response_function.qualified_arn
      include_body = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = var.project_name
  }
}

# Cache Policy for optimized image caching
resource "aws_cloudfront_cache_policy" "optimized" {
  name        = "${var.project_name}-cache-policy"
  comment     = "Optimized cache policy for image resizing"
  default_ttl = 86400
  max_ttl     = 31536000
  min_ttl     = 1

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["Accept"]
      }
    }

    query_strings_config {
      query_string_behavior = "whitelist"
      query_strings {
        items = ["d"]
      }
    }

    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

# Origin Request Policy to forward necessary headers
resource "aws_cloudfront_origin_request_policy" "custom" {
  name    = "${var.project_name}-origin-request-policy"
  comment = "Custom origin request policy for Lambda@Edge"

  cookies_config {
    cookie_behavior = "none"
  }

  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Accept"]
    }
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}
