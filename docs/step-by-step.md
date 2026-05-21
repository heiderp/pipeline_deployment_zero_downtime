# Step-by-Step Guide — Zero Downtime Pipeline

This guide walks through the entire project lifecycle: from a clean checkout to a
fully operational Blue/Green deployment pipeline on AWS ECS.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Clone and Configure](#2-clone-and-configure)
3. [Terraform State Backend (one-time)](#3-terraform-state-backend-one-time)
4. [First Infrastructure Deploy (dev)](#4-first-infrastructure-deploy-dev)
5. [Build and Push Docker Images](#5-build-and-push-docker-images)
6. [Build the Rollback Lambda Zip](#6-build-the-rollback-lambda-zip)
7. [Configure GitHub Secrets](#7-configure-github-secrets)
8. [Trigger the First Deployment](#8-trigger-the-first-deployment)
9. [Verify the Deployment](#9-verify-the-deployment)
10. [Test Health Checks and Rollback](#10-test-health-checks-and-rollback)
11. [Tear Down](#11-tear-down)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Prerequisites

Make sure these tools are installed and configured:

```bash
# Verify installations
aws --version          # ≥ 2.15
terraform --version    # ≥ 1.6
docker --version       # ≥ 24
gh --version           # ≥ 2.40
python3 --version      # ≥ 3.11
node --version         # ≥ 20
java --version         # ≥ 21

# AWS credentials must be configured
aws configure
# Enter: AWS Access Key ID, Secret Access Key, region=us-east-1
```

> **IAM permissions**: the AWS user needs admin-equivalent permissions for the PoC
> (ECS, ECR, ALB, RDS, SQS, SNS, Lambda, CloudWatch, IAM, S3, DynamoDB).

---

## 2. Clone and Configure

```bash
# Clone the repo
git clone <your-repo-url> pipeline_deployment_zero_downtime
cd pipeline_deployment_zero_downtime

# Set up local environment
cp .env.example .env
# Edit .env — replace CHANGE_ME values (ignore for now, used later)
```

---

## 3. Terraform State Backend (one-time)

The Terraform configuration uses a remote backend (S3 + DynamoDB). Create it once:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"

# Create S3 bucket for state files
aws s3 mb s3://${ACCOUNT_ID}-tfstate --region $REGION

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket ${ACCOUNT_ID}-tfstate \
  --versioning-configuration Status=Enabled

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $REGION

echo "State backend ready."
```

---

## 4. First Infrastructure Deploy (dev)

### 4.1 Configure environment variables for Terraform

```bash
cd infra

# Copy the example and fill in real values
cp environments/dev.tfvars.example environments/dev.tfvars
```

Edit `environments/dev.tfvars`:

```hcl
environment = "dev"
aws_region  = "us-east-1"

tf_state_bucket     = "<ACCOUNT_ID>-tfstate"   # from step 3
tf_state_lock_table = "tfstate-lock"

rds_username = "dbadmin"
rds_password = "ChangeMe123!"                   # pick a strong password
```

### 4.2 Initialize and apply

```bash
# Initialize Terraform (downloads providers + configures backend)
terraform init

# Preview changes
terraform plan -var-file=environments/dev.tfvars

# Apply (creates all AWS resources — takes ~10 minutes)
terraform apply -var-file=environments/dev.tfvars
```

Terraform will output the ARNs and endpoints. Save them:

```bash
terraform output -json > ../outputs.json
```

Key outputs to note:
```
alb_dns_name          = "dev-alb-123456.us-east-1.elb.amazonaws.com"
ecr_flask_url         = "123456.dkr.ecr.us-east-1.amazonaws.com/dev-flask-app"
ecr_node_url          = "123456.dkr.ecr.us-east-1.amazonaws.com/dev-node-app"
ecr_spring_url        = "123456.dkr.ecr.us-east-1.amazonaws.com/dev-spring-app"
flask_blue_tg_arn     = "arn:aws:elasticloadbalancing:..."
node_blue_tg_arn      = "..."
spring_blue_tg_arn    = "..."
# ... and corresponding green TGs, listener rules, service names
```

---

## 5. Build and Push Docker Images

The pipeline builds and pushes images, but the **first deployment** needs images
in ECR. Build them manually once:

```bash
cd ..

# Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com

# Build and push Flask
cd apps/flask-app
docker build -t ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/dev-flask-app:latest .
docker push ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/dev-flask-app:latest
cd ../..

# Build and push Node
cd apps/node-app
docker build -t ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/dev-node-app:latest .
docker push ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/dev-node-app:latest
cd ../..

# Build and push Spring (takes longer — Java build)
cd apps/spring-app
docker build -t ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/dev-spring-app:latest .
docker push ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/dev-spring-app:latest
cd ../..
```

Verify images are in ECR:

```bash
aws ecr describe-images --repository-name dev-flask-app --region us-east-1
```

---

## 6. Build the Rollback Lambda Zip

```bash
cd infra/lambda
zip rollback.zip index.py
cd ../..
```

The pipeline in `.github/workflows/deploy.yml` references this zip when
rebuilding the Lambda. In a production setup you'd automate this step.

---

## 7. Configure GitHub Secrets

Run `gh` CLI or use the GitHub UI (Settings → Secrets and variables → Actions).

### 7.1 Required Secrets

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# AWS credentials (you need an IAM user with CI/CD permissions)
gh secret set AWS_ACCESS_KEY_ID --body "<your-access-key>"
gh secret set AWS_SECRET_ACCESS_KEY --body "<your-secret-key>"
gh secret set AWS_ACCOUNT_ID --body "$ACCOUNT_ID"

# RDS credentials (same as in dev.tfvars)
gh secret set RDS_USERNAME --body "dbadmin"
gh secret set RDS_PASSWORD --body "ChangeMe123!"

# Slack (optional — leave empty for now)
gh secret set SLACK_WEBHOOK_URL --body ""
```

### 7.2 Per-Service Target Group and Rule ARNs

Extract from `terraform output`:

```bash
cd infra

gh secret set ALB_DNS_NAME --body "$(terraform output -raw alb_dns_name)"
gh secret set ALB_LISTENER_ARN --body "$(terraform output -raw alb_listener_arn)"

gh secret set FLASK_RULE_ARN --body "$(terraform output -raw flask_listener_rule_arn)"
gh secret set FLASK_BLUE_TG_ARN --body "$(terraform output -raw flask_blue_tg_arn)"
gh secret set FLASK_GREEN_TG_ARN --body "$(terraform output -raw flask_green_tg_arn)"

gh secret set NODE_RULE_ARN --body "$(terraform output -raw node_listener_rule_arn)"
gh secret set NODE_BLUE_TG_ARN --body "$(terraform output -raw node_blue_tg_arn)"
gh secret set NODE_GREEN_TG_ARN --body "$(terraform output -raw node_green_tg_arn)"

gh secret set SPRING_RULE_ARN --body "$(terraform output -raw spring_listener_rule_arn)"
gh secret set SPRING_BLUE_TG_ARN --body "$(terraform output -raw spring_blue_tg_arn)"
gh secret set SPRING_GREEN_TG_ARN --body "$(terraform output -raw spring_green_tg_arn)"

cd ..
```

Verify:

```bash
gh secret list
```

---

## 8. Trigger the First Deployment

Push to `main` — this triggers the full pipeline:

```bash
# Make a small change to trigger the pipeline
echo "# Trigger CI" >> README.md
git add README.md
git commit -m "ci: trigger first pipeline run"
git push origin main
```

Watch the pipeline in GitHub:

```bash
gh run watch
# Or: open https://github.com/<owner>/<repo>/actions
```

The workflow has 15 jobs that run in sequence:
```
test → build → terraform-plan → terraform-apply → deploy-green →
health-check → shift-traffic → bake → cleanup-blue
                                                    └→ rollback (on failure)
```

**Expected duration**: ~15–20 minutes for the first run.

---

## 9. Verify the Deployment

### 9.1 Check the ALB

```bash
ALB_DNS=$(terraform -chdir=infra output -raw alb_dns_name)

# Test Flask
curl http://${ALB_DNS}/flask/health
# → {"database":"healthy","service":"healthy","sns":"unconfigured","sqs":"healthy"}

# Test Node
curl http://${ALB_DNS}/node/health
# → {"service":"healthy","sqs":"healthy"}

# Test Spring
curl http://${ALB_DNS}/spring/health
# → {"service":"healthy","sns":"healthy","sqs":"unconfigured"}
```

### 9.2 Check ECS

```bash
aws ecs list-services --cluster dev-cluster
aws ecs describe-services --cluster dev-cluster --services dev-flask dev-node dev-spring \
  --query 'services[*].[serviceName,desiredCount,runningCount,status]'
```

### 9.3 Check CloudWatch

```bash
# Open the dashboard
open "https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=dev-pipeline-dashboard"

# Or via CLI
aws cloudwatch get-dashboard --dashboard-name dev-pipeline-dashboard
```

---

## 10. Test Health Checks and Rollback

### 10.1 Force a simulated failure

The easiest way to test rollback is to deploy a broken image:

```bash
# Create a "broken" version that fails health checks
cd apps/flask-app

# Break the health endpoint temporarily
sed -i 's/return jsonify(checks)/return jsonify({"error":"simulated failure"}), 500/' app.py

# Build and push as a new version
docker build -t ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/dev-flask-app:broken .
docker push ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/dev-flask-app:broken

# Revert the break
git checkout app.py
cd ../..
```

Then trigger a new deployment — the health check job should fail, and the
rollback job should fire.

### 10.2 Verify rollback worked

```bash
# After the rollback, check that the ALB is still serving traffic
curl http://${ALB_DNS}/flask/health

# Check CloudWatch alarms
aws cloudwatch describe-alarms --alarm-name-prefix dev-Green --state-value ALARM

# Check Lambda logs
aws logs tail /aws/lambda/dev-ecs-rollback --follow
```

### 10.3 Test the Lambda directly

```bash
aws lambda invoke \
  --function-name dev-ecs-rollback \
  --payload '{"alarmName":"manual-test","alarmData":{"alarmName":"manual-test"}}' \
  response.json

cat response.json
```

---

## 11. Tear Down

When you're done with the PoC:

```bash
# Destroy all AWS resources
cd infra
terraform destroy -var-file=environments/dev.tfvars

# Delete the state backend
aws s3 rb s3://${ACCOUNT_ID}-tfstate --force
aws dynamodb delete-table --table-name tfstate-lock --region us-east-1
```

---

## 12. Troubleshooting

### Terraform apply fails with "S3 bucket does not exist"

You forgot step 3. Create the state backend first.

### ECS tasks are stuck in PENDING or fail to start

```bash
# Check stopped tasks for the reason
aws ecs describe-tasks --cluster dev-cluster --tasks <task-id>

# Common causes:
# - ECR image not found → did you push images in step 5?
# - IAM role missing ECR permission → check aws_iam_role_policy_attachment.ecs_task_execution
# - Subnet has no NAT gateway → check VPC configuration
```

### Health check returns 503

```bash
# Check target group health
aws elbv2 describe-target-health --target-group-arn <blue-tg-arn>

# Check ECS service events
aws ecs describe-services --cluster dev-cluster --services dev-flask --query 'services[0].events[0:5]'
```

### Pipeline fails on terraform-plan with "Permission denied"

The GitHub Actions IAM user needs `s3:GetObject` on the state bucket and
`dynamodb:GetItem` on the lock table. Update the IAM policy.

### Rollback Lambda not triggering

```bash
# Check if the alarm is in ALARM state
aws cloudwatch describe-alarms --state-value ALARM

# Check Lambda invocation errors
aws logs tail /aws/lambda/dev-ecs-rollback

# Verify alarm action
aws cloudwatch describe-alarms --alarm-names dev-Green-HighErrorRate \
  --query 'MetricAlarms[0].AlarmActions'
```
