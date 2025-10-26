# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an AWS Lambda@Edge image optimization system that dynamically resizes images at CloudFront edge locations. Infrastructure is managed with Terraform and deployed via GitHub Actions using OIDC authentication.

**Key Architecture**:
1. **Viewer Request** (`lambda-functions/viewer-request/`): URI rewriting based on `?d=WxH` query parameter and WebP detection
2. **Origin Response** (`lambda-functions/origin-response/`): On-demand image resizing with Sharp, S3 caching (fire-and-forget), base64 response
3. **Terraform**: Single-environment infrastructure, lambda-edge module with placeholder code, GitHub Actions deployment
4. **CloudFront**: OAC for S3, Lambda@Edge associations with versioned ARNs

## Critical Constraints & Common Pitfalls

### Lambda@Edge Specific Constraints

**IMPORTANT: These are non-negotiable AWS Lambda@Edge limitations that MUST be followed:**

1. **Region Requirement**:
   - Lambda@Edge functions MUST be created in **us-east-1 only**
   - Always use `provider = aws.us-east-1` alias in Terraform
   - Never change this region or deployments will fail

2. **No Environment Variables**:
   - Lambda@Edge does NOT support environment variables
   - S3 bucket name is hardcoded as `__S3_BUCKET_PLACEHOLDER__` in `origin-response/index.mjs`
   - GitHub Actions workflow replaces this placeholder during deployment
   - NEVER try to use Lambda environment variables or Terraform `environment {}` blocks

3. **Response Size Limits**:
   - Viewer/Origin request: 1MB maximum response size
   - Origin response: 1MB maximum response size (base64-encoded images ~750KB actual size)
   - Images larger than this will fail - this is an AWS hard limit

4. **CloudFront ARN Requirements**:
   - Lambda@Edge associations MUST use **versioned ARNs** (e.g., `arn:...:function:name:5`)
   - NEVER use `$LATEST` - CloudFront will reject it
   - Always publish versions and use qualified ARNs

5. **Deployment Timing**:
   - CloudFront distribution updates take 15-30 minutes to propagate
   - Lambda@Edge function updates are not immediate
   - Do not expect instant deployment results

### Terraform Lifecycle Management

**CRITICAL: Code deployment is split between Terraform and GitHub Actions:**

1. **Terraform's Role**:
   - Creates Lambda functions with **placeholder code only**
   - Uses `lifecycle { ignore_changes = [filename, source_code_hash] }` in `terraform/modules/lambda-edge/main.tf`
   - Manages infrastructure (S3, CloudFront, IAM, networking)
   - NEVER manages actual Lambda function code after initial creation

2. **GitHub Actions' Role**:
   - Deploys ALL Lambda function code updates
   - Replaces `__S3_BUCKET_PLACEHOLDER__` with actual bucket name
   - Publishes new versions with qualified ARNs
   - Updates CloudFront distribution (manual workflow)

3. **Common Mistake**:
   - DO NOT try to update Lambda code via Terraform
   - DO NOT remove `ignore_changes` from lifecycle blocks
   - DO NOT expect `terraform apply` to deploy code changes

### Backend Configuration

**State Management**:
- Uses **local backend** (not S3)
- State file: `terraform/terraform.tfstate`
- State file is in `.gitignore` - never commit it
- No backend configuration file needed (removed `backend.tfvars`)

### File Extension vs Handler Path

**Handler Configuration**:
- Files use `.mjs` extension (ES modules): `index.mjs`
- Handler path is `index.handler` (references base name without extension)
- This is correct and intentional - Lambda Node.js runtime supports this
- NEVER change handler to `index.mjs.handler`

### AWS SDK in Lambda Runtime

**Dependencies**:
- `@aws-sdk/client-s3` is specified as **devDependency** in `origin-response/package.json`
- This is CORRECT because AWS Lambda runtime includes AWS SDK v3 by default
- The SDK is NOT bundled in function.zip (excluded by `--omit=dev`)
- Only `sharp` is bundled as a production dependency
- NEVER move `@aws-sdk/client-s3` to dependencies

## Commands

### Terraform Operations (via Task)

```bash
task init      # Initialize Terraform (local backend)
task plan      # Plan infrastructure changes
task apply     # Apply infrastructure changes
task destroy   # Destroy all resources
task format    # Format Terraform code
task validate  # Validate Terraform configuration
```

### Lambda Function Development

```bash
task install-deps  # Install dependencies for all functions
task test          # Run tests (if configured)
task lint          # Run ESLint
task clean         # Remove .terraform, node_modules, *.zip

# Local testing
cd lambda-functions/viewer-request
node debug.mjs     # Test viewer-request locally

cd lambda-functions/origin-response
node debug.mjs     # Test origin-response (requires S3 access)
```

### Manual Lambda Deployment (Rare)

```bash
cd lambda-functions/viewer-request
npm ci --omit=dev
npm run package
aws lambda update-function-code \
  --function-name {PROJECT_NAME}-viewer-request \
  --zip-file fileb://function.zip \
  --region us-east-1
```

**WARNING**: Remember to replace `__S3_BUCKET_PLACEHOLDER__` before manual deployment.

## Important Implementation Details

### When Modifying Lambda Functions

1. **Viewer Request Function**:
   - Zero dependencies (lightweight)
   - Rewrites URI from `/path/file.jpg?d=300x300` to `/resize/path/300x300/webp/file.jpg`
   - Detects WebP from `Accept: image/webp` header
   - Returns modified `request` object to CloudFront

2. **Origin Response Function**:
   - Dependencies: `sharp` (production), `@aws-sdk/client-s3` (devDependency - provided by Lambda runtime)
   - Processes 404/403 responses only
   - Fetches from S3: `origin/{subpath}/{filename}`
   - Resizes with Sharp: `fit: inside`, `withoutEnlargement: true`, auto-rotation
   - Uploads to S3: `resize/{path}/{width}x{height}/{format}/{filename}` (async fire-and-forget)
   - Returns base64-encoded image immediately (does not wait for upload)
   - Max dimensions: 4000px (validated before processing)

3. **S3 Bucket Name Replacement**:
   - Source code contains `__S3_BUCKET_PLACEHOLDER__`
   - GitHub Actions workflow uses `sed` to replace with actual bucket from secrets
   - Happens in `.github/workflows/deploy-lambda.yaml` during build step
   - Never hardcode bucket names in source code

4. **Package Building**:
   - `npm ci --omit=dev` excludes devDependencies (AWS SDK not bundled)
   - `npm run package` creates function.zip with index.mjs + package.json + node_modules/
   - Sharp includes native Linux binaries (compiled during npm install in GitHub Actions)

### When Modifying Terraform

1. **Provider Configuration**:
   - Primary: `aws` (region from `var.aws_region`, default: "ap-northeast-1")
   - Alias: `aws.us-east-1` (hardcoded to us-east-1 for Lambda@Edge)
   - Both have default tags: `Project` and `ManagedBy`

2. **Lambda@Edge Module** (`terraform/modules/lambda-edge/`):
   - Creates empty placeholder Lambda with minimal code
   - Required variables: `function_name`, `log_region`
   - Optional: `s3_bucket_arn` (for S3 permissions), `timeout`, `memory_size`, `runtime`
   - ALWAYS include `providers = { aws.us-east-1 = aws.us-east-1 }`
   - `var.log_region` is required (no default) - specifies where CloudWatch logs aggregate

3. **CloudFront Distribution** (`terraform/main.tf`):
   - Lambda associations use `module.*.qualified_arn` (versioned ARN)
   - `wait_for_deployment = false` for faster Terraform apply
   - Cache policy whitelists: `Accept` header, `d` query string
   - Origin path: `/origin` (S3 subdirectory)

4. **S3 Bucket Lifecycle** (`terraform/main.tf:82-114`):
   - Resized images (`resize/` prefix) expire after **7 days** (hardcoded)
   - Incomplete multipart uploads aborted after 7 days
   - NOT configurable via variables - directly change in main.tf if needed

5. **IAM Permissions**:
   - GitHub Actions role: Lambda update, CloudFront management, `lambda:EnableReplication*`
   - Lambda execution roles: S3 read from `origin/*`, S3 write to `resize/*`
   - CloudWatch Logs restricted to `var.log_region` only

6. **Versioned ARNs**:
   - Lambda@Edge module outputs `qualified_arn` with `:1` version suffix
   - CloudFront requires this for Lambda associations
   - GitHub Actions publishes new versions and updates CloudFront separately

### When Modifying GitHub Actions Workflows

1. **deploy-lambda.yaml**:
   - Triggered on push to main with changes in `lambda-functions/`
   - Matrix builds both functions in parallel
   - Key step: `sed -i "s/__S3_BUCKET_PLACEHOLDER__/${{ secrets.S3_BUCKET }}/g"`
   - Uses OIDC authentication (no long-lived credentials)
   - Publishes version after code update: `aws lambda publish-version`

2. **update-cloudfront.yaml**:
   - Manual trigger only (`workflow_dispatch`)
   - Finds CloudFront distribution by project name comment
   - Uses `jq` to update Lambda associations in distribution config
   - Requires ETag for conditional update (prevents conflicts)

3. **cleanup-lambda-versions.yaml**:
   - Manual trigger, keeps latest 2 versions (hardcoded in workflow)
   - Deletes older versions: `aws lambda delete-function --qualifier {VERSION}`

### GitHub Secrets Required

- `AWS_ROLE_ARN`: GitHub Actions IAM role ARN (from Terraform output)
- `PROJECT_NAME`: Used for function naming: `{PROJECT_NAME}-viewer-request`
- `S3_BUCKET`: Replaces `__S3_BUCKET_PLACEHOLDER__` during deployment

## Request Flow Architecture

```
User Request: /blog/image.jpg?d=300x300 (Accept: image/webp)
    ↓
CloudFront → Lambda@Edge (Viewer Request)
    ↓ Rewrites URI to: /resize/blog/300x300/webp/image.jpg
CloudFront Cache Check
    ↓ Cache MISS
S3 Origin Check: /resize/blog/300x300/webp/image.jpg
    ↓ 404 Not Found
Lambda@Edge (Origin Response)
    ↓ Fetch original: origin/blog/image.jpg
    ↓ Resize with Sharp
    ↓ Upload to S3: resize/blog/300x300/webp/image.jpg (async)
    ↓ Return base64-encoded image immediately
CloudFront caches response (Cache-Control: max-age=86400)
    ↓
User receives resized image
```

## S3 Bucket Structure

```
s3://{bucket-name}/
├── origin/                  # Original images (uploaded by user)
│   └── blog/
│       └── image.jpg
└── resize/                  # Auto-generated resized images (7-day lifecycle)
    └── blog/
        └── 300x300/
            └── webp/
                └── image.jpg
```

## Terraform Variables

**Required** (in `terraform.tfvars`):
- `project_name`: Resource naming prefix
- `s3_bucket_name`: Globally unique S3 bucket name
- `github_repo`: Format "owner/repo" for OIDC trust

**Optional** (with defaults):
- `aws_region`: Main region (default: "ap-northeast-1")

**Removed Variables**:
- `resized_images_expiration_days`: Now hardcoded to 7 days in main.tf:95

## Deployment Flow

1. **Initial Setup** (one-time):
   - Create GitHub OIDC provider in AWS
   - Copy `terraform.tfvars.example` to `terraform.tfvars`
   - Run `task init && task apply`
   - Configure GitHub Secrets (AWS_ROLE_ARN, PROJECT_NAME, S3_BUCKET)

2. **Code Deployment** (automatic):
   - Push to main → GitHub Actions deploys Lambda functions
   - Publishes new versions with qualified ARNs

3. **CloudFront Update** (manual):
   - Manually trigger "Update CloudFront Distribution" workflow
   - Updates Lambda@Edge associations with latest versions
   - Propagates in 15-30 minutes

4. **Version Cleanup** (optional):
   - Manually trigger "Cleanup Old Lambda Versions" workflow
   - Keeps latest 2 versions, deletes older ones

## Common Mistakes to Avoid

1. ❌ Adding environment variables to Lambda@Edge functions
2. ❌ Using `$LATEST` ARN for CloudFront associations
3. ❌ Deploying Lambda@Edge to regions other than us-east-1
4. ❌ Trying to update Lambda code with `terraform apply`
5. ❌ Hardcoding S3 bucket name in source code
6. ❌ Moving `@aws-sdk/client-s3` to dependencies (it's provided by Lambda runtime)
7. ❌ Removing `lifecycle { ignore_changes }` from Lambda resources
8. ❌ Expecting immediate CloudFront distribution updates (15-30 min propagation)
9. ❌ Committing `terraform.tfstate` to git
10. ❌ Using `backend.tfvars` (backend is now local, not S3)

## File Locations Reference

| Path | Purpose |
|------|---------|
| `lambda-functions/viewer-request/index.mjs` | URI rewrite logic |
| `lambda-functions/origin-response/index.mjs` | Image resizing with Sharp |
| `terraform/main.tf` | All infrastructure resources |
| `terraform/modules/lambda-edge/main.tf` | Reusable Lambda@Edge module |
| `terraform/variables.tf` | Variable definitions |
| `terraform/outputs.tf` | Output definitions (GitHub Actions role ARN, etc.) |
| `.github/workflows/deploy-lambda.yaml` | Automatic Lambda deployment |
| `.github/workflows/update-cloudfront.yaml` | Manual CloudFront update |
| `.github/workflows/cleanup-lambda-versions.yaml` | Manual version cleanup |
| `Taskfile.yaml` | Task automation (init, plan, apply, etc.) |
| `compose.yaml` | Docker services for Terraform/AWS CLI |

## Key Technical Decisions

1. **Fire-and-forget S3 upload**: Origin-response returns image immediately without waiting for S3 upload to complete (better performance)
2. **Placeholder replacement**: S3 bucket name replaced at build time (avoids environment variables limitation)
3. **Split deployment**: Terraform for infrastructure, GitHub Actions for code (avoids Terraform state drift)
4. **OIDC authentication**: Modern keyless approach (no long-lived AWS credentials in GitHub)
5. **Local backend**: Simplified state management (no S3 backend needed for single-developer projects)
6. **Versioned ARNs**: CloudFront requires explicit versions (not $LATEST)
7. **Sharp native binaries**: Built in Linux environment via GitHub Actions (not buildable on macOS)
8. **7-day lifecycle**: Resized images expire after 7 days (reduces S3 storage costs)
