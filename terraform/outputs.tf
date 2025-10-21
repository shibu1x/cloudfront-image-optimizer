output "viewer_request_function" {
  description = "Viewer request function details"
  value = {
    arn           = module.viewer_request_function.function_arn
    qualified_arn = module.viewer_request_function.qualified_arn
    version       = module.viewer_request_function.version
  }
}

output "origin_response_function" {
  description = "Origin response function details"
  value = {
    arn           = module.origin_response_function.function_arn
    qualified_arn = module.origin_response_function.qualified_arn
    version       = module.origin_response_function.version
  }
}

output "github_actions_role" {
  description = "GitHub Actions IAM role details"
  value = {
    role_arn          = aws_iam_role.github_actions.arn
    role_name         = aws_iam_role.github_actions.name
    oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  }
}

output "s3_origin_bucket" {
  description = "S3 origin bucket details"
  value = {
    bucket_id                   = aws_s3_bucket.origin.id
    bucket_arn                  = aws_s3_bucket.origin.arn
    bucket_domain_name          = aws_s3_bucket.origin.bucket_domain_name
    bucket_regional_domain_name = aws_s3_bucket.origin.bucket_regional_domain_name
    origin_access_control_id    = aws_cloudfront_origin_access_control.s3_origin.id
  }
}

output "cloudfront_distribution" {
  description = "CloudFront distribution details"
  value = {
    id                       = aws_cloudfront_distribution.main.id
    arn                      = aws_cloudfront_distribution.main.arn
    domain_name              = aws_cloudfront_distribution.main.domain_name
    hosted_zone_id           = aws_cloudfront_distribution.main.hosted_zone_id
    status                   = aws_cloudfront_distribution.main.status
    cache_policy_id          = aws_cloudfront_cache_policy.optimized.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.custom.id
  }
}
