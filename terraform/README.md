# Terraform Configuration

This directory contains Terraform configuration for the CloudFront Image Optimizer infrastructure.

## Structure

```
terraform/
├── main.tf                     # Main infrastructure configuration (all resources)
├── variables.tf                # Variable definitions
├── outputs.tf                  # Output definitions
├── terraform.tfvars.example    # Example variables file
├── backend.tfvars.example      # Example backend configuration
└── modules/
    └── lambda-edge/            # Lambda@Edge function module
```

## Prerequisites

1. **AWS Account**: You need an AWS account with appropriate permissions
2. **GitHub OIDC Provider**: Must be created in your AWS account first
   ```bash
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com \
     --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
   ```
3. **S3 Bucket for Terraform State**: Create an S3 bucket for storing Terraform state

## Setup

### 1. Configure Variables

Copy the example files and customize them:

```bash
cp terraform.tfvars.example terraform.tfvars
cp backend.tfvars.example backend.tfvars
```

Edit `terraform.tfvars`:
```hcl
aws_region   = "ap-northeast-1"
project_name = "my-image-optimizer"

# S3 bucket name for CloudFront origin (must be globally unique)
s3_bucket_name = "my-image-optimizer-origin"

# GitHub repository in format "owner/repo"
github_repo = "your-username/your-repo"
```

Edit `backend.tfvars`:
```hcl
bucket = "your-terraform-state-bucket"
region = "ap-northeast-1"
```

### 2. Initialize Terraform

```bash
# Using Task (recommended)
task init

# Or using Docker Compose directly
cd terraform
docker compose run --rm terraform init -backend-config="backend.tfvars"
```

### 3. Plan Infrastructure

```bash
# Using Task
task plan

# Or using Docker Compose
cd terraform
docker compose run --rm terraform plan
```

### 4. Deploy Infrastructure

```bash
# Using Task
task apply

# Or using Docker Compose
cd terraform
docker compose run --rm terraform apply
```

## Key Variables

| Variable | Description | Required | Default |
|----------|-------------|----------|---------|
| `project_name` | Project name for resource naming | Yes | - |
| `s3_bucket_name` | S3 bucket name for CloudFront origin | Yes | - |
| `github_repo` | GitHub repository (owner/repo) | Yes | - |
| `aws_region` | AWS region for main resources | No | ap-northeast-1 |

## Outputs

After deployment, Terraform will output:

- **CloudFront Distribution**: Domain name and ID
- **Lambda Functions**: ARNs and versions
- **S3 Bucket**: Bucket details
- **GitHub Actions Role**: IAM role ARN for CI/CD

Use these outputs to configure your GitHub repository secrets:

```bash
terraform output -json
```

## Architecture

The infrastructure creates:

1. **S3 Bucket Resources**:
   - S3 bucket for CloudFront origin
   - Public access blocking
   - Server-side encryption (AES256)
   - Lifecycle rules for resized images cleanup
   - CloudFront Origin Access Control (OAC)
   - Bucket policy for Lambda@Edge access
2. **Lambda@Edge Functions** (us-east-1):
   - Viewer Request: URI rewriting based on query parameters
   - Origin Response: Dynamic image resizing
3. **CloudFront Distribution**: CDN with Lambda@Edge associations, cache policies, and origin request policies
4. **GitHub Actions IAM Resources**:
   - IAM role with OIDC trust for GitHub Actions
   - Lambda update policy
   - CloudFront management policy
5. **CloudWatch Log Groups**: Logging for Lambda@Edge functions

## Lambda@Edge Constraints

- Functions **must** be in `us-east-1` region
- Functions cannot use environment variables
- Code updates should be done via GitHub Actions
- Terraform ignores code changes after initial deployment

## Clean Up

To destroy all infrastructure:

```bash
# Using Task
task destroy

# Or using Docker Compose
cd terraform
docker compose run --rm terraform destroy
```

## Troubleshooting

### Backend Initialization Fails

Ensure your S3 bucket for Terraform state exists and `backend.tfvars` contains the correct bucket name.

### GitHub OIDC Provider Not Found

Create the GitHub OIDC provider in your AWS account (see Prerequisites).

### S3 Bucket Name Already Exists

S3 bucket names must be globally unique. Choose a different name in `terraform.tfvars`.

## Additional Commands

```bash
# Format Terraform code
task format

# Validate configuration
task validate

# Clean temporary files
task clean
```
