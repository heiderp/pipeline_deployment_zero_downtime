# GitHub Secrets — Required Configuration

This document lists all GitHub Secrets and Variables that must be configured
for the CI/CD pipeline (`deploy.yml`) to function.

## How to Set

```bash
# Via GitHub CLI
gh secret set SECRET_NAME --body "value" --repo owner/repo

# Or via GitHub UI
# Settings → Secrets and variables → Actions → New repository secret
```

---

## Required Secrets

| Secret Name | Description | Where Used |
|-------------|-------------|------------|
| `AWS_ACCESS_KEY_ID` | AWS IAM access key (CI/CD user) | All jobs that call AWS APIs |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM secret key (CI/CD user) | All jobs that call AWS APIs |
| `AWS_ACCOUNT_ID` | 12-digit AWS account ID | ECR registry URL construction |

> **IAM permissions needed** by the CI/CD user:
> - `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:CompleteLayerUpload`, `ecr:InitiateLayerUpload`, `ecr:PutImage`, `ecr:UploadLayerPart`
> - `ecs:UpdateService`, `ecs:DescribeServices`, `ecs:DescribeTaskDefinition`, `ecs:RegisterTaskDefinition`
> - `elasticloadbalancing:ModifyRule`, `elasticloadbalancing:DescribeRules`
> - `cloudwatch:DescribeAlarms`
> - `s3:GetObject`, `s3:PutObject` (Terraform state)
> - `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:DeleteItem` (Terraform lock)

## Infrastructure Secrets (passed to Terraform)

| Secret Name | Description | Terraform Variable |
|-------------|-------------|--------------------|
| `RDS_USERNAME` | RDS master username | `rds_username` |
| `RDS_PASSWORD` | RDS master password | `rds_password` |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook for notifications | `slack_webhook_url` |

## Pipeline Configuration Secrets

| Secret Name | Description | Default |
|-------------|-------------|---------|
| `ALB_DNS_NAME` | ALB DNS endpoint for health checks | — |
| `ALB_LISTENER_ARN` | ARN of the main ALB listener | — |
| `BLUE_TG_ARN` | Blue target group ARN (deprecated, now per-service) | — |
| `GREEN_TG_ARN` | Green target group ARN (deprecated, now per-service) | — |
| `FLASK_BLUE_TG_ARN` | Flask blue target group ARN | — |
| `FLASK_GREEN_TG_ARN` | Flask green target group ARN | — |
| `NODE_BLUE_TG_ARN` | Node blue target group ARN | — |
| `NODE_GREEN_TG_ARN` | Node green target group ARN | — |
| `SPRING_BLUE_TG_ARN` | Spring blue target group ARN | — |
| `SPRING_GREEN_TG_ARN` | Spring green target group ARN | — |

> Note: The per-service target group ARNs are outputs of `terraform apply`. Run
> `terraform output` in the `infra/` directory to get them, then set as secrets.

## Terraform State Backend (manual setup)

Before running Terraform for the first time, create the state backend:

```bash
# Create S3 bucket
aws s3 mb s3://<account>-tfstate --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket <account>-tfstate \
  --versioning-configuration Status=Enabled

# Create DynamoDB lock table
aws dynamodb create-table \
  --table-name tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Then update `infra/environments/{env}.tfvars` with:
```hcl
tf_state_bucket     = "<account>-tfstate"
tf_state_lock_table = "tfstate-lock"
```

## Environment Variables (non-sensitive, set as Variables)

| Variable Name | Description |
|---------------|-------------|
| `AWS_REGION` | AWS region (default: `us-east-1`) |
| `ECR_REGISTRY` | ECR registry URL pattern (constructed from `AWS_ACCOUNT_ID`) |
| `ENVIRONMENT` | Deployment target (`dev`, `staging`, or `prod`) |

---

## Verification

After setting all secrets, test the pipeline with a manual trigger:

```bash
# Push to main to trigger
git push origin main

# Or run via GitHub CLI
gh workflow run deploy.yml --ref main
```

Check the Actions tab in GitHub for the workflow run status.
