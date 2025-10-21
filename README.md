# Lambda@Edge Functions with Terraform

This project provides an AWS Lambda@Edge-based image resizing system that dynamically resizes and optimizes images at CloudFront edge locations. Infrastructure is managed with Terraform and deployed via GitHub Actions.

## Directory Structure

```
.
├── lambda-functions/           # Lambda@Edge function source code
│   ├── viewer-request/        # Viewer request function
│   └── origin-response/       # Origin response function
├── terraform/                 # Terraform configuration
│   ├── modules/
│   │   └── lambda-edge/      # Lambda@Edge function module
│   ├── main.tf               # Main infrastructure (S3, CloudFront, IAM, etc.)
│   ├── variables.tf          # Variable definitions
│   ├── outputs.tf            # Output definitions
│   ├── terraform.tfvars.example    # Example variables file
│   └── backend.tfvars.example      # Backend configuration template
├── .github/
│   └── workflows/            # CI/CD workflows
│       ├── deploy-lambda.yaml          # Lambda function deployment
│       ├── update-cloudfront.yaml      # CloudFront distribution update
│       └── cleanup-lambda-versions.yaml # Lambda version cleanup
└── Taskfile.yaml             # Task runner configuration
```

## How It Works

This project implements on-demand image resizing using two Lambda@Edge functions:

### 1. Viewer Request Function
**Location**: `lambda-functions/viewer-request/`

Intercepts CloudFront requests and rewrites URIs based on query parameters:

- Parses `?d=WIDTHxHEIGHT` dimension parameter (e.g., `?d=300x300`)
- Detects WebP support from `Accept` header
- Rewrites URI to: `/resize/{path}/{width}x{height}/{format}/{filename}.{ext}`

**Example**:
- Input: `/blog/posts/image.jpg?d=300x300` (with WebP support)
- Output: `/resize/blog/posts/300x300/webp/image.jpg`

### 2. Origin Response Function
**Location**: `lambda-functions/origin-response/`

Handles 404/403 responses for missing resized images:

- Fetches original image from S3: `origin/{path}/{filename}`
- Resizes using Sharp library with the specified dimensions
- Uploads resized image to S3 (fire-and-forget for performance)
- Returns base64-encoded image immediately to CloudFront

**Features**:
- WebP format conversion support
- Maximum dimension limit: 4000px
- `fit: inside` with `withoutEnlargement: true` (maintains aspect ratio)
- Auto-rotation based on EXIF data

### Image Storage Structure

```
S3 Bucket:
├── origin/              # Original images
│   └── {path}/
│       └── {filename}
└── resize/              # Cached resized images (auto-deleted after 1 day)
    └── {path}/
        └── {width}x{height}/
            └── {format}/
                └── {filename}
```

## Setup

### Prerequisites

- AWS CLI configured
- Terraform >= 1.0
- Node.js >= 22.x (for Lambda function development)
- [Task](https://taskfile.dev/) (optional, task runner)
- Docker (optional, for Terraform via Docker Compose)

### 1. Configure Backend

Create backend configuration file:

```bash
# Copy template
cp terraform/backend.tfvars.example terraform/backend.tfvars

# Edit and set your S3 bucket name for Terraform state
# Example:
# bucket = "my-terraform-state"
# region = "ap-northeast-1"
```

**Note**: Add `terraform/backend.tfvars` to `.gitignore` for security.

### 2. Create Variables File

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Edit terraform/terraform.tfvars with your values:
cat > terraform/terraform.tfvars <<EOF
aws_region     = "ap-northeast-1"
project_name   = "my-image-optimizer"
s3_bucket_name = "my-image-optimizer-origin"  # Must be globally unique
github_repo    = "your-username/your-repo-name"
EOF
```

**Note**: Add `terraform/terraform.tfvars` to `.gitignore` for security.

### 3. Create GitHub Actions OIDC Provider (First Time Only)

Create an OIDC Provider to allow GitHub Actions to access AWS. **Execute once per AWS account**.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

Skip this step if the OIDC Provider already exists.

### 4. Initialize Terraform

```bash
# Using Task (recommended)
task init

# Or directly with Docker Compose
cd terraform
docker compose run --rm terraform init -backend-config="backend.tfvars"
```

### 5. Deploy Infrastructure

Terraform will deploy the following:
- S3 bucket for image storage with CloudFront OAC
- Lambda@Edge functions (created with placeholder code)
- CloudFront distribution with Lambda@Edge associations
- GitHub Actions IAM role (using existing OIDC Provider)
- CloudWatch Log Groups for Lambda@Edge

```bash
# Using Task
task plan
task apply

# Or directly
cd terraform
docker compose run --rm terraform plan
docker compose run --rm terraform apply
```

**Important**:
- Terraform uses `lifecycle { ignore_changes = [filename, source_code_hash] }`, so function code changes after initial deployment are not managed by Terraform
- Update Lambda code via GitHub Actions or manually

### 6. Configure GitHub Repository Secrets

Add the following secrets to your GitHub repository:

1. Go to: `Settings` → `Secrets and variables` → `Actions` → `New repository secret`
2. Add these secrets:
   - `AWS_ROLE_ARN`: Get from Terraform output (`github_actions_role_arn`)
   - `PROJECT_NAME`: Your project name (e.g., "my-image-optimizer")
   - `S3_BUCKET`: S3 origin bucket name from Terraform output

```bash
# Get the role ARN from Terraform
cd terraform
docker compose run --rm terraform output github_actions_role_arn
```

### 7. Deploy Lambda Function Code

Push to the main branch to automatically deploy Lambda functions:

```bash
git add lambda-functions/
git commit -m "Initial Lambda function code"
git push origin main
```

The GitHub Actions workflow will:
1. Build Lambda function packages
2. Replace `__S3_BUCKET_PLACEHOLDER__` with actual bucket name
3. Deploy to AWS Lambda
4. Publish new versions

### 8. Update CloudFront Distribution (Manual)

After deploying Lambda functions, attach them to CloudFront:

1. Go to GitHub Actions tab
2. Select "Update CloudFront Distribution" workflow
3. Click "Run workflow"
4. Run

This will update your CloudFront distribution with the latest Lambda@Edge function versions.

## Task Management with Taskfile

This project uses [Task](https://taskfile.dev/) to manage commonly used commands.

### Available Tasks

```bash
# Show all tasks
task --list

# Initialize Terraform
task init

# Deploy infrastructure
task plan
task apply

# Lambda function development
task install-deps    # Install dependencies for all functions
task test            # Run tests for all functions
task lint            # Run linter for all functions

# Terraform maintenance
task format          # Format Terraform code
task validate        # Validate Terraform configuration

# Clean up
task clean           # Remove .terraform, builds, node_modules, *.zip
```

## GitHub Actions Workflows

### 1. Deploy Lambda Functions (Automatic)

**File**: `.github/workflows/deploy-lambda.yaml`

**Trigger**: Push to `main` branch with changes in `lambda-functions/`

**What it does**:
- Installs dependencies
- Replaces S3 bucket placeholder with actual bucket name
- Builds function.zip packages
- Deploys to AWS Lambda via OIDC authentication
- Publishes new versions
- Outputs qualified ARNs

### 2. Update CloudFront Distribution (Manual)

**File**: `.github/workflows/update-cloudfront.yaml`

**Trigger**: Manual (`workflow_dispatch`)

**What it does**:
- Finds CloudFront distribution by project name
- Fetches latest Lambda function versions
- Updates Lambda@Edge associations on CloudFront
- Outputs deployment summary

**Usage**:
1. Go to GitHub Actions tab
2. Select "Update CloudFront Distribution"
3. Click "Run workflow"

### 3. Cleanup Old Lambda Versions (Manual)

**File**: `.github/workflows/cleanup-lambda-versions.yaml`

**Trigger**: Manual (`workflow_dispatch`)

**What it does**:
- Lists all Lambda function versions
- Keeps latest 2 versions
- Deletes older versions
- Outputs cleanup summary

**Usage**:
1. Go to GitHub Actions tab
2. Select "Cleanup Old Lambda Versions"
3. Click "Run workflow"

## Lambda Function Development

### Local Development

Each function includes a `debug.mjs` file for local testing:

```bash
# Test viewer request function
cd lambda-functions/viewer-request
npm install
node debug.mjs

# Test origin response function (requires S3 access)
cd lambda-functions/origin-response
npm install
node debug.mjs
```

### Running Tests

```bash
# Test all functions
task test

# Or test individually
cd lambda-functions/viewer-request
npm test
```

### Linting

```bash
# Lint all functions
task lint

# Or lint individually
cd lambda-functions/viewer-request
npm run lint
```

### Manual Deployment (Optional)

To deploy manually without using GitHub Actions:

```bash
cd lambda-functions/viewer-request
npm install --omit=dev
npm run package

aws lambda update-function-code \
  --function-name my-image-optimizer-viewer-request \
  --zip-file fileb://function.zip \
  --region us-east-1
```

**Note**: Remember to replace `__S3_BUCKET_PLACEHOLDER__` in `origin-response/index.mjs` before manual deployment.

## Lambda@Edge Constraints

- **Region**: Functions must be created in the us-east-1 region
- **Timeout**: Maximum 30 seconds (5 seconds recommended for viewer/origin request)
- **Memory**: Maximum 10,240 MB (128 MB configured)
- **Package Size**:
  - viewer request/response: 1 MB (compressed)
  - origin request/response: 50 MB (compressed)
- **Environment Variables**: Not available (use constants in code instead)
- **VPC**: Cannot run inside a VPC
- **Runtime**: Uses Node.js ES modules (`.mjs` files)

## Terraform Configuration

### Infrastructure Resources

All resources are defined in `terraform/main.tf`:
- S3 bucket (versioning disabled, encryption enabled)
- S3 bucket lifecycle rules (resized images auto-delete after 1 day)
- CloudFront Origin Access Control (OAC)
- Lambda@Edge functions (via module)
- S3 bucket policy (allows CloudFront + Lambda@Edge access)
- GitHub Actions IAM role with OIDC trust
- CloudFront distribution with cache/origin request policies
- CloudWatch Log Groups (in main region for Lambda@Edge logs)

### Backend Configuration

This project uses S3 backend with partial configuration:

- **State file key**: `cloudfront/terraform.tfstate`
- **Encryption**: Disabled (`encrypt = false`)
- **Locking**: Uses S3-based lockfile (`.terraform.lock.hcl`)

Backend settings (`bucket` and `region`) are provided via `backend.tfvars` file.

**Security Note**: Do not commit `backend.tfvars` or `terraform.tfvars` to public repositories. Use `.example` files as templates.

### Required Variables

- `project_name`: Project name for resource naming
- `s3_bucket_name`: S3 bucket name for CloudFront origin (must be globally unique)
- `github_repo`: GitHub repository in format "owner/repo"

### Optional Variables

- `aws_region`: AWS region for main resources (default: "ap-northeast-1")

### Function Naming Convention

Lambda functions are named: `{PROJECT_NAME}-{function-type}`

Example: `my-image-optimizer-viewer-request`

## Troubleshooting

### Lambda@Edge Function Not Updating

Lambda@Edge functions are replicated across the entire CloudFront distribution, so updates take time (15-30 minutes). They are not deleted immediately upon deletion either.

### Checking Function Logs

Lambda@Edge logs are recorded in CloudWatch Logs. Check the main region (configured in terraform.tfvars) for aggregated logs at:
- `/aws/lambda/us-east-1.{PROJECT_NAME}-viewer-request`
- `/aws/lambda/us-east-1.{PROJECT_NAME}-origin-response`

### S3 Bucket Not Found Error

If you see errors like "NoSuchBucket" in the origin-response function:
1. Ensure the S3 bucket exists in the specified region
2. Verify `S3_BUCKET` secret is correctly set in GitHub
3. Check the Lambda execution role has S3 read/write permissions (managed by Terraform)

### Image Not Resizing

1. Check CloudWatch Logs for errors in the origin-response function
2. Verify original image exists at `origin/{path}/{filename}` in S3
3. Ensure image dimensions are within limits (max 4000px)
4. Confirm Sharp library is properly bundled with node_modules
5. Test locally using `debug.mjs` scripts

### Terraform State Lock Error

If you encounter state lock errors:
1. Ensure `.terraform.lock.hcl` file in S3 is not corrupted
2. Check S3 bucket permissions allow reading/writing lockfile
3. Wait a few minutes if another operation is in progress
4. As last resort, manually remove `.terraform.lock.hcl` from S3 (use with caution)

### GitHub Actions Deployment Fails

1. Verify `AWS_ROLE_ARN` secret is correct
2. Check OIDC provider exists in AWS IAM
3. Ensure Lambda function names match expected format: `{PROJECT_NAME}-{function}`
4. Verify IAM role has necessary Lambda update permissions

## Security Considerations

When using this project, especially in public repositories:

1. **Never commit sensitive files**:
   - `terraform/terraform.tfvars` (contains project configuration)
   - `terraform/backend.tfvars` (contains state bucket name)
   - Add these to `.gitignore`

2. **Use GitHub Secrets** for:
   - `AWS_ROLE_ARN`
   - `PROJECT_NAME`
   - `S3_BUCKET`

3. **Limit IAM permissions**:
   - GitHub Actions role only has Lambda update permissions
   - Lambda execution roles follow principle of least privilege

4. **S3 Access Control**:
   - S3 bucket uses CloudFront OAC for public access
   - Lambda@Edge has direct access to read `origin/*` and write `resize/*`
   - All public access is blocked at the bucket level

5. **Rate limiting**:
   - Consider implementing rate limiting in Lambda@Edge functions
   - Use AWS WAF with CloudFront for additional protection

6. **Monitoring**:
   - Enable CloudWatch alarms for Lambda errors
   - Monitor CloudFront logs for unusual patterns

## References

- [AWS Lambda@Edge Documentation](https://docs.aws.amazon.com/lambda/latest/dg/lambda-edge.html)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [CloudFront Functions vs Lambda@Edge](https://aws.amazon.com/blogs/aws/introducing-cloudfront-functions-run-your-code-at-the-edge-with-low-latency-at-any-scale/)
- [Sharp Image Processing](https://sharp.pixelplumbing.com/)
- [Task Runner](https://taskfile.dev/)

## License

MIT
