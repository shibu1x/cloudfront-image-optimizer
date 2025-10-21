variable "aws_region" {
  description = "AWS region for the main provider"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket for CloudFront origin"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in the format 'owner/repo-name'"
  type        = string
}
