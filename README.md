# Pipeline Deployment — Zero Downtime

Proof of Concept for a continuous delivery pipeline with **Blue/Green deployments on AWS ECS**, zero service interruption, automatic health checks, and rollback.

## Quick Links

- **[AGENTS.md](./AGENTS.md)** — Project map, restrictions, directory index, and conventions.
- **[patterns/architecture.md](./patterns/architecture.md)** — System architecture and data flow.
- **[patterns/blue-green.md](./patterns/blue-green.md)** — Blue/Green deployment strategy details.
- **[patterns/rollback.md](./patterns/rollback.md)** — Automatic rollback strategy.

## Prerequisites

- AWS account with appropriate IAM permissions
- Terraform ≥ 1.6
- Docker
- [Floci](https://floci.dev) for local testing
- GitHub repository with Actions enabled

## Quick Start

```bash
# 1. Clone the repo
git clone <repo-url> && cd pipeline_deployment_zero_downtime

# 2. Set up environment
cp .env.example .env
# Edit .env with your AWS credentials and preferences

# 3. Run local tests
floci run

# 4. Deploy infrastructure (dev)
cd infra
terraform init
terraform apply -var-file=environments/dev.tfvars

# 5. Push to main to trigger the pipeline
git push origin main
```

## Architecture

```
GitHub push → GitHub Actions
                ├─ Lint & Test (Floci)
                ├─ Build Docker images → ECR
                ├─ Terraform plan/apply
                ├─ ECS Blue/Green deploy
                ├─ Health checks (CloudWatch)
                └─ Success → Cleanup blue
                   Failure → Rollback + Notify
```
