variable "function_name" {
  description = "Name of the Lambda@Edge function"
  type        = string
}

variable "runtime" {
  description = "Lambda runtime"
  type        = string
  default     = "nodejs22.x"
}

variable "handler" {
  description = "Lambda function handler"
  type        = string
  default     = "index.handler"
}

variable "timeout" {
  description = "Function timeout in seconds (max 30 for Lambda@Edge)"
  type        = number
  default     = 5
}

variable "memory_size" {
  description = "Memory allocated to the function in MB (max 10240 for Lambda@Edge)"
  type        = number
  default     = 128
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "s3_bucket_arn" {
  description = "ARN of the S3 bucket for origin images (optional)"
  type        = string
  default     = ""
}

variable "log_region" {
  description = "AWS region where CloudWatch Logs should be created"
  type        = string
}

# Create a minimal empty Lambda function code
data "archive_file" "empty_lambda" {
  type        = "zip"
  output_path = "${path.module}/builds/${var.function_name}-empty.zip"

  source {
    content  = "exports.handler = async (event) => { return event.Records[0].cf.request; };"
    filename = "index.js"
  }
}

# IAM role for Lambda@Edge
resource "aws_iam_role" "lambda_edge_role" {
  name = "${var.function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = [
            "lambda.amazonaws.com",
            "edgelambda.amazonaws.com"
          ]
        }
      }
    ]
  })

  tags = var.tags
}

# Custom logging policy - restrict to specific region only
resource "aws_iam_role_policy" "lambda_edge_logging" {
  name = "lambda-edge-logging-policy"
  role = aws_iam_role.lambda_edge_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.log_region}:*:log-group:/aws/lambda/*"
      }
    ]
  })
}

# S3 access policy for origin-response function
# Note: Policy is always created. If s3_bucket_arn is empty, permissions are still granted
# but will be managed via S3 bucket policy in main.tf
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-access-policy"
  role = aws_iam_role.lambda_edge_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      var.s3_bucket_arn != "" ? [
        {
          Effect = "Allow"
          Action = [
            "s3:GetObject"
          ]
          Resource = "${var.s3_bucket_arn}/origin/*"
        },
        {
          Effect = "Allow"
          Action = [
            "s3:PutObject",
            "s3:PutObjectAcl"
          ]
          Resource = "${var.s3_bucket_arn}/resize/*"
        }
      ] : [],
      []
    )
  })
}

# CloudWatch Log Group for Lambda function
resource "aws_cloudwatch_log_group" "lambda_log_group" {
  provider = aws.us-east-1

  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 1

  tags = var.tags
}

# Lambda function
resource "aws_lambda_function" "function" {
  # Lambda@Edge functions must be created in us-east-1
  provider = aws.us-east-1

  filename         = data.archive_file.empty_lambda.output_path
  function_name    = var.function_name
  role             = aws_iam_role.lambda_edge_role.arn
  handler          = var.handler
  source_code_hash = data.archive_file.empty_lambda.output_base64sha256
  runtime          = var.runtime
  timeout          = var.timeout
  memory_size      = var.memory_size
  publish          = true # Must be true for Lambda@Edge

  tags = var.tags

  # Ignore changes to filename to allow manual updates
  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash
    ]
  }

  # Ensure log group is created before Lambda function
  depends_on = [aws_cloudwatch_log_group.lambda_log_group]
}

# Lambda permission for CloudFront to invoke and replicate the function
resource "aws_lambda_permission" "allow_cloudfront" {
  provider = aws.us-east-1

  statement_id  = "AllowExecutionFromCloudFront"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.function.function_name
  principal     = "edgelambda.amazonaws.com"
}

# CloudWatch Log Group for Lambda@Edge in main region
# Lambda@Edge logs are restricted to specified region only via IAM policy
# This prevents automatic log group creation in other regions
resource "aws_cloudwatch_log_group" "lambda_edge_main_region" {
  # Use main provider (specified region, not us-east-1)
  name              = "/aws/lambda/us-east-1.${var.function_name}"
  retention_in_days = 1

  tags = var.tags
}

output "function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.function.arn
}

output "qualified_arn" {
  description = "Qualified ARN of the Lambda function (includes version)"
  value       = aws_lambda_function.function.qualified_arn
}

output "version" {
  description = "Latest published version of the Lambda function"
  value       = aws_lambda_function.function.version
}

output "role_arn" {
  description = "ARN of the IAM role"
  value       = aws_iam_role.lambda_edge_role.arn
}

output "role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.lambda_edge_role.name
}

output "function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.function.function_name
}
