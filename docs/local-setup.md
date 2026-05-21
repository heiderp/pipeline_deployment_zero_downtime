# Local Development Setup

## Prerequisites

- **Docker** ≥ 24.x
- **Python** 3.11+ (for the Flask app)
- **Node.js** 20.x (for the Node app)
- **Java** 21 (for the Spring app)
- **Terraform** ≥ 1.6
- **Floci** CLI (for local testing)
- **AWS CLI** (configured with credentials)
- **LocalStack** (optional, for local AWS service emulation)

## Quick Start

```bash
# 1. Clone and enter the project
git clone <repo-url>
cd pipeline_deployment_zero_downtime

# 2. Set up environment
cp .env.example .env
# Edit .env with your values

# 3. Start local AWS services (optional, via LocalStack)
docker compose -f docker-compose.local.yml up -d

# 4. Run all tests
floci run test-all

# 5. Deploy infrastructure (dev)
cd infra
cp environments/dev.tfvars.example environments/dev.tfvars
# Edit dev.tfvars with your AWS account details
terraform init
terraform plan -var-file=environments/dev.tfvars
terraform apply -var-file=environments/dev.tfvars
```

## LocalStack Setup (Optional)

For local development without real AWS resources, use LocalStack:

```bash
# Start LocalStack with required services
docker run --rm -d \
  --name localstack \
  -p 4566:4566 \
  -p 4510-4559:4510-4559 \
  -e SERVICES=sqs,sns,rds,ecs,ecr,cloudwatch,iam \
  localstack/localstack:latest

# Create test SQS queue
aws --endpoint-url=http://localhost:4566 sqs create-queue --queue-name dev-tasks-queue

# Create test SNS topic
aws --endpoint-url=http://localhost:4566 sns create-topic --name dev-events-topic
```

## Running Individual Apps

### Flask App

```bash
cd apps/flask-app
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python app.py
```

### Node App

```bash
cd apps/node-app
npm install
npm start
```

### Spring App

```bash
cd apps/spring-app
./gradlew bootRun
```

## Testing with Floci

```bash
# Run all unit tests
floci run test-all

# Run a single suite
floci run flask-unit

# Run in CI mode (JUnit output)
floci run --ci
```

## GitHub Actions Local Testing

Use [act](https://github.com/nektos/act) to test workflows locally:

```bash
# Install act
brew install act  # macOS
# or: curl https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash

# Run the deploy workflow locally
act push -j test --secret-file .env
```
