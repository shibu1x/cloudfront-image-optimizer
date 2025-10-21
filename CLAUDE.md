# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an AWS Lambda@Edge image optimization system that dynamically resizes images at CloudFront edge locations. The infrastructure is managed with Terraform and deployed via GitHub Actions using OIDC authentication.

### Key Architecture

1. **Viewer Request Function** (`lambda-functions/viewer-request/`): Intercepts CloudFront requests and rewrites URIs based on query parameters. Parses `?d=WxH` dimension parameter and detects WebP support from Accept headers to construct optimized paths like `/resize/{path}/{width}x{height}/{format}/{filename}`.

2. **Origin Response Function** (`lambda-functions/origin-response/`): Handles 404/403 responses for missing resized images. Fetches original from S3, resizes using Sharp library, uploads result to S3 (fire-and-forget), and returns base64-encoded image immediately. Uses pattern `origin/{subpath}/{filename}` for source images.

3. **Terraform Structure**: Single-environment configuration with one reusable module:
   - All infrastructure resources are defined directly in `terraform/main.tf`
   - `terraform/modules/lambda-edge/`: Lambda@Edge function module with empty placeholder code (uses lifecycle ignore_changes for filename/hash)
   - No environment separation - single `terraform.tfvars` and `backend.tfvars` files

4. **Infrastructure Resources** (all in `main.tf`):
   - S3 bucket with versioning disabled, encryption, lifecycle rules (resized images expire after 1 day)
   - CloudFront distribution with OAC (Origin Access Control)
   - Lambda@Edge functions (via module)
   - GitHub Actions IAM role with OIDC trust
   - CloudFront cache policies and origin request policies
   - CloudWatch log groups for Lambda@Edge (in main region)

### Critical Constraints

- Lambda@Edge functions **must** be in us-east-1 region (enforced via provider alias)
- Lambda@Edge cannot use environment variables (S3 bucket name hardcoded as `__S3_BUCKET_PLACEHOLDER__` in origin-response/index.mjs)
- Function code uses `.mjs` extension (ES modules), but package.json references `index.js` - this is intentional for Lambda compatibility
- Terraform ignores code changes after initial deployment (lifecycle ignore_changes in modules/lambda-edge/main.tf) - code updates go through GitHub Actions only
- GitHub OIDC provider must exist before Terraform runs
- Resized images lifecycle: hardcoded to 1 day expiration (not configurable via variables)

### S3 Backend Configuration

Terraform uses S3 backend with partial configuration:
- `terraform/backend.tfvars` contains bucket and region (not committed to git)
- `terraform/backend.tfvars.example` is the template
- State file path: `cloudfront/terraform.tfstate` (hardcoded in main.tf)
- Encryption disabled, uses S3-based locking via `.terraform.lock.hcl`

## Commands

### Task Runner (Preferred Method)

This project uses [Task](https://taskfile.dev/). All commands assume you're in the project root.

```bash
# Terraform operations
task init                    # Initialize Terraform with backend config
task plan                    # Plan changes
task apply                   # Apply changes
task destroy                 # Destroy infrastructure

# Lambda development
task install-deps            # Install dependencies for all functions
task test                    # Run tests for all functions
task lint                    # Run linter for all functions

# Maintenance
task format                  # Format Terraform code
task validate                # Validate Terraform configuration
task clean                   # Remove .terraform, builds, node_modules
```

### Direct Commands (Alternative)

If Task is not available:

```bash
# Terraform via Docker Compose
cd terraform
docker compose run --rm terraform init -backend-config="backend.tfvars"
docker compose run --rm terraform plan
docker compose run --rm terraform apply

# Lambda function development
cd lambda-functions/viewer-request
npm install
npm test                     # Run all tests
npm run lint                 # Run ESLint
npm run package              # Create function.zip

# Manual Lambda deployment (rarely needed - prefer GitHub Actions)
aws lambda update-function-code \
  --function-name {PROJECT_NAME}-viewer-request \
  --zip-file fileb://function.zip \
  --region us-east-1
```

### GitHub Actions Workflows

1. **deploy-lambda.yaml**: Push to main branch automatically deploys Lambda functions
   - Detects changes under `lambda-functions/`
   - Runs tests (continues on failure)
   - Replaces `__S3_BUCKET_PLACEHOLDER__` with actual bucket from secrets
   - Builds zip package excluding test files
   - Updates Lambda code via OIDC authentication
   - Publishes new version and outputs qualified ARN

2. **update-cloudfront.yaml**: Manual workflow to update CloudFront distribution with latest Lambda versions
   - Finds CloudFront distribution by project name (no environment suffix)
   - Fetches latest Lambda function versions
   - Updates Lambda@Edge associations
   - Triggered via `workflow_dispatch`

3. **cleanup-lambda-versions.yaml**: Manual workflow to delete old Lambda versions
   - Keeps latest 2 versions (hardcoded, not configurable)
   - Deletes older versions to reduce clutter
   - Triggered via `workflow_dispatch` (no inputs required)

## Important Implementation Notes

### When Modifying Lambda Functions

1. **S3 Bucket Configuration**: The deploy-lambda workflow automatically replaces `__S3_BUCKET_PLACEHOLDER__` with the value from GitHub Secrets (`S3_BUCKET`). Do not hardcode bucket names in the source code.

2. **Handler Path**: Lambda handler is `index.handler` but files are `.mjs` - this works because Lambda Node.js runtime supports ES modules

3. **Sharp Library**: Origin-response uses Sharp for image processing - it has native dependencies that require Linux build environment (handled automatically by GitHub Actions using `npm ci --omit=dev`)

4. **Response Size Limits**: Lambda@Edge viewer/origin request functions have 1MB response limit; origin-response can return up to 1MB base64-encoded image

5. **Testing**: Each function includes `debug.mjs` for local testing. Run with `node debug.mjs` to simulate CloudFront events.

### When Modifying Terraform

1. **Provider Context**: Lambda@Edge resources must use `provider = aws.us-east-1` alias (already configured in modules)

2. **State Management**: Uses S3 backend with partial configuration. Must specify `-backend-config` during `terraform init`:
   ```bash
   terraform init -backend-config="backend.tfvars"
   ```

3. **No Environment Separation**:
   - Single `terraform.tfvars` and `backend.tfvars` (not committed)
   - Use `.example` files as templates
   - Function naming: `{PROJECT_NAME}-viewer-request`, `{PROJECT_NAME}-origin-response` (no environment suffix)

4. **Module Updates**: The lambda-edge module is in `terraform/modules/lambda-edge/`. If changing Lambda function configuration, note that:
   - Module creates empty placeholder Lambda functions
   - Actual code deployment happens via GitHub Actions
   - `var.log_region` is required (not optional, no default value)

5. **CloudFront Distribution**: CloudFront distribution is managed in `terraform/main.tf` with Lambda@Edge associations. ARNs must be versioned qualifiers (`:N` suffix), not `$LATEST`.

6. **S3 Bucket Policy**: Direct S3 access is allowed for Lambda@Edge functions to read from `origin/*` and write to `resize/*`. CloudFront uses OAC for access.

### GitHub Actions Setup Requirements

GitHub repository secrets needed:
- `AWS_ROLE_ARN`: Output from Terraform (`github_actions_role_arn`)
- `PROJECT_NAME`: Used to construct function names (e.g., "blog-media")
- `S3_BUCKET`: S3 origin bucket name (replaced in code during deployment)

Function naming convention: `{PROJECT_NAME}-{function-type}` (no environment suffix)

### Terraform Variables

Required variables in `terraform.tfvars`:
- `project_name`: Project name for resource naming
- `s3_bucket_name`: S3 bucket name for CloudFront origin (must be globally unique)
- `github_repo`: GitHub repository in format "owner/repo"

Optional variables with defaults:
- `aws_region`: AWS region for main resources (default: "ap-northeast-1")

Note: `resized_images_expiration_days` was removed - expiration is hardcoded to 1 day in main.tf

## Deployment Flow

1. **Initial Setup**:
   - Create GitHub OIDC provider in AWS (one-time per account):
     ```bash
     aws iam create-open-id-connect-provider \
       --url https://token.actions.githubusercontent.com \
       --client-id-list sts.amazonaws.com \
       --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
     ```
   - Copy `backend.tfvars.example` and `terraform.tfvars.example` to actual files
   - Configure with your values
   - Run `task init` to initialize Terraform with backend
   - Run `task apply` to create Lambda functions, S3 bucket, CloudFront distribution, and GitHub Actions IAM role

2. **Code Deployment**:
   - Push code to main branch → GitHub Actions builds and deploys → publishes versioned ARN
   - Manually trigger "Update CloudFront Distribution" workflow to attach new Lambda versions

3. **Version Cleanup** (optional):
   - Manually trigger "Cleanup Old Lambda Versions" workflow
   - Keeps latest 2 versions, removes older versions
