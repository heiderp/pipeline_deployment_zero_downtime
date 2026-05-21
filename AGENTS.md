# AGENTS.md — pipeline_deployment_zero_downtime

## Project Overview

Proof of Concept (PoC) that demonstrates a continuous delivery pipeline capable of deploying new application versions **without service interruption** (zero downtime). The project simulates the real-world problem of companies that lose availability during each deploy.

### What This Project Delivers

- Integration with **GitHub Actions** as CI/CD orchestrator.
- **Blue/Green deployment** strategy on **AWS ECS** (native 2025 support, no CodeDeploy dependency).
- **Automatic health checks** against latency, error rate, and throughput metrics.
- **Automatic rollback** if the new (green) environment fails validation.
- Infrastructure as Code via **Terraform**.
- Local testing harness via **Floci**.

### Trigger

A `git push` to `main` triggers the entire process — build, test, deploy, validate — with **no manual intervention**.

### Application Stack (Hybrid, Placeholder)

| Component         | Runtime      | Role                             |
| ----------------- | ------------ | -------------------------------- |
| `apps/flask-app`  | Python/Flask | Monolith (API + SQS/SNS + RDS)   |
| `apps/node-app`   | Node.js      | Microservice #1 (SQS consumer)   |
| `apps/spring-app` | Java/Spring  | Microservice #2 (SNS subscriber) |

These are minimal "hello-world" applications, designed to be **replaced** with real services once the pipeline is validated.

---

## Directory Index

| Directory             | Purpose                                                    |
| --------------------- | ---------------------------------------------------------- |
| `.github/workflows/`  | GitHub Actions CI/CD pipeline definitions                  |
| `infra/`              | Terraform Infrastructure as Code (ECS, ALB, SQS, SNS, RDS) |
| `infra/environments/` | Per-environment `.tfvars` (dev, staging, prod)             |
| `apps/`               | Placeholder application source code                        |
| `patterns/`           | Architecture patterns and deployment strategy docs         |
| `docs/`               | Setup guides, runbooks, ADRs                               |
| `floci.yaml`          | Floci configuration for local testing                      |
| `AGENTS.md`           | This file — project map, restrictions, conventions         |
| `README.md`           | Thin project intro, links here for details                 |

---

## Project Restrictions

All contributors and agents MUST respect these constraints:

### Infrastructure

1. **IaC only**: Every AWS resource must be defined in Terraform. No ClickOps.
2. **Remote state**: Terraform state stored in S3 with DynamoDB locking.
3. **Environment isolation**: Separate workspaces or `.tfvars` per environment (`dev`, `staging`, `prod`).
4. **Least privilege IAM**: Each ECS task gets only the permissions it needs (SQS, SNS, RDS, ECR pull).

### Deployment

5. **Blue/Green mandatory**: No in-place updates. Every deploy creates a new task set.
6. **Traffic shift via ALB**: The Application Load Balancer routes traffic between blue and green.
7. **Health gate before shift**: Green must pass 100% of health checks before any production traffic hits it.
8. **Rollback is automatic**: If green fails, traffic reverts to blue immediately. No manual approval loop.

### Testing

9. **Unit tests pass = gate**: A push that fails unit tests never reaches deployment.
10. **Floci is the local runner**: All local test execution goes through Floci (`floci.yaml`).
11. **Health endpoint required**: Every service exposes `GET /health` returning JSON with dependency status.

### Code & Docs

12. **AGENTS.md is the canonical project map**: README.md is a thin pointer.
13. **Patterns are documented**: Every architectural decision lives in `patterns/`.
14. **Environment variables never committed**: `.env` is gitignored; `.env.example` is the template.

---

## Best Practices (AWS Expert Recommendations)

### Blue/Green on ECS (Native, 2025)

Amazon ECS now supports **native Blue/Green deployments** without AWS CodeDeploy. The deployment lifecycle has six phases:

1. **Preparation** — Register new task definition, create green task set.
2. **Deployment** — Launch green tasks, wait for steady state.
3. **Testing** — Run validation (health checks, smoke tests).
4. **Traffic Shift** — Move ALB traffic from blue to green (can be gradual: canary or linear).
5. **Monitoring (Bake Time)** — Observe green for N minutes under real traffic.
6. **Cleanup** — Drain and terminate blue tasks.

### Rollback Strategy

- **CloudWatch Alarms** monitor green: error rate > 5%, p99 latency > 2s, throughput drop > 20%.
- On alarm breach → **Lambda function** triggers ECS `rollback` API to revert traffic to blue.
- Team is **notified via Slack/email** (success and failure).
- The commit that caused the failure is **tagged** in git for post-mortem.

### Terraform Conventions

- **Modular design**: `infra/` uses Terraform modules where possible.
- **State locking**: S3 backend with DynamoDB.
- **Variables by environment**: `infra/environments/{env}.tfvars`.
- **Secrets**: RDS passwords, API keys stored in AWS Secrets Manager, referenced via Terraform `data` sources — never in `.tfvars`.

### Pipeline (GitHub Actions)

- Single workflow file triggers on `push` to `main`.
- Steps: lint → test → build images → push to ECR → Terraform apply → deploy ECS (Blue/Green) → health check → bake → cleanup or rollback.
- AWS credentials stored as **GitHub Secrets** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).
- ECR repository URL and ECS cluster/service names passed as workflow variables.

### Observability

- **CloudWatch Dashboard** with: request count, error rate, p50/p99 latency, ECS task health.
- **CloudWatch Logs** from every ECS service.
- **Alarms** wired to rollback Lambda.

---

## Conventions

- Commits follow [Conventional Commits](https://www.conventionalcommits.org/).
- Branch strategy: `main` only for this PoC (simplicity).
- Language for artifacts (code, comments, commits, docs): **English**.
- Terraform formatting: `terraform fmt` before commit.
