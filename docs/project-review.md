# Project Review — pipeline_deployment_zero_downtime

**Date:** 2026-05-20
**Model:** Claude Sonnet 4.6
**Stage:** Initial PoC

---

## Purpose

CI/CD pipeline PoC for zero-downtime deployments on AWS ECS. Push to `main` → GitHub Actions → build/test → push ECR → Terraform apply → Blue/Green deploy with canary (10→50→100%) → 5-min bake → cleanup blue, or automatic rollback if CloudWatch alarms trigger.

Three placeholder apps (Flask monolith + Node SQS consumer + Spring SNS subscriber) on VPC/ALB/ECS Fargate/RDS PG16/SQS/SNS, with a rollback Lambda and CloudWatch dashboard.

---

## What Works Well

- **Clear separation**: `infra/` (Terraform), `apps/` (services), `patterns/` (architecture decisions), `docs/` (runbooks), `.github/workflows/` (CI). Standard layout.
- **Canonical AGENTS.md** with explicit restrictions (IaC only, remote state, least-privilege IAM, Blue/Green mandatory). Thin README points to it.
- **Per-service Blue/Green**: 6 target groups (blue+green × 3 apps), 3 path-based listener rules. Correct for multi-service.
- **Two-layer rollback**: reactive Lambda (CloudWatch alarms) + `rollback` workflow job (failure-triggered). Appropriate redundancy for PoC.
- **Good Terraform conventions**: default tags on provider, `force_delete` only for `!= prod`, log/backup retention conditional by env, `image_tag_mutability=IMMUTABLE`, ECR lifecycle (keep last 10), `deployment_circuit_breaker` enabled.
- **Remote state** S3+DynamoDB declared. `.env.example` + gitignore. Per-env tfvars.
- **Floci** as local runner consistent with CI.
- **step-by-step.md** (438 lines) serves as onboarding guide.

---

## Gaps and Risks

### Critical

**1. Not real Blue/Green — it's rolling.**
ECS services use `ignore_changes = [task_definition, load_balancer]` and the workflow uses `--force-new-deployment`. That triggers a **rolling update**, not Blue/Green. True Blue/Green requires either:
- `deployment_controller { type = "EXTERNAL" }` + explicit `aws_ecs_task_set` resources, or
- `deployment_controller { type = "CODE_DEPLOY" }` with CodeDeploy integration.
The project title and docs promise Blue/Green but the implementation is rolling.

**2. `shift-traffic` job has a loop bug.**
The loop iterates over `FLASK_RULE_ARN`, `NODE_RULE_ARN`, `SPRING_RULE_ARN` but the `--actions` body hardcodes `FLASK_BLUE_TG_ARN` and `FLASK_GREEN_TG_ARN` for all three services. Node and Spring never shift correctly.

**3. Missing `aws_lambda_permission` for CloudWatch → Lambda.**
CloudWatch alarms point directly to the Lambda ARN in `alarm_actions`, but Lambda requires an explicit resource-based permission from `lambda.alarms.cloudwatch.amazonaws.com`. Without it, CloudWatch cannot invoke the rollback Lambda — rollback silently fails.

**4. RDS password in plaintext.**
AGENTS.md mandates Secrets Manager for passwords, but `var.rds_password` is passed as `TF_VAR_rds_password` plain text. Violates the project's own rule.

**5. `DATABASE_URL` with embedded password in container env vars.**
Plaintext in ECS API responses and potentially in logs. Use `secrets` (Secrets Manager ARN reference) in the container definition instead.

---

### Structural

**6. `main.tf` is a monolith (1079 lines).**
AGENTS.md says "modular design" but there are no `modules/`. Target groups for Flask/Node/Spring are copy-pasted three times. Suggested modules: `network`, `ecs-service`, `bluegreen-tg`, `rollback`.

**7. `rollback.zip` is a committed binary.**
Binary files in git cause noisy diffs and can get out of sync with `index.py`. Replace with an `archive_file` data source in Terraform — it builds the zip from source at plan time.

**8. `ECR_REGISTRY` env var references `env.AWS_REGION` in the same `env:` block.**
GitHub Actions does not expand `env.X` references within the same `env:` block. `ECR_REGISTRY` will contain the literal string `${{ env.AWS_REGION }}` instead of the region value. The ECR login URL will be malformed.

---

### Observability

**9. `task_unhealthy` alarm only monitors `flask_green` target group.**
Node and Spring green task groups have no equivalent alarm. Partial rollback coverage.

**10. `low_throughput` alarm can trigger spurious rollbacks.**
Fires if request count drops below threshold — will trigger outside peak hours or during low-traffic periods. Reconsider threshold or remove this alarm; it's unsuitable as a rollback gate.

---

### Testing and CI

**11. No real tests.**
`tests/test_app.py`, `tests/test.js`, `ApplicationTests.java` are placeholders. `floci run --ci` would pass trivially or fail. Unit test gate (#9 in AGENTS.md restrictions) is not enforced.

**12. No Terraform linting in CI.**
AGENTS.md requires `terraform fmt` before commit, but there's no `terraform fmt -check`, `tflint`, or `tfsec` step in the workflow.

---

### Minor

**13. No LICENSE file.**
**14. No CHANGELOG.**

---

## Verdict

**8/10 for initial phase.** Solid skeleton, architecture decisions documented, explicit restrictions. Main gap: misalignment between **promise (native Blue/Green + Secrets Manager + modular Terraform)** and **current implementation (rolling deploys, plaintext password, monolithic main.tf)**.

### Priority order to fix

| Priority | Fix |
|----------|-----|
| 1 | Implement real Blue/Green (`aws_ecs_task_set`) or update docs to reflect rolling |
| 2 | Fix `shift-traffic` loop bug (Node/Spring use Flask TG ARNs) |
| 3 | Add `aws_lambda_permission` (CloudWatch → rollback Lambda) |
| 4 | RDS password → Secrets Manager |
| 5 | `DATABASE_URL` → use `secrets` in container def |
| 6 | Fix `ECR_REGISTRY` env var expansion in workflow |
| 7 | Modularize `main.tf` |
| 8 | Replace `rollback.zip` with `archive_file` data source |
| 9 | Add per-service `task_unhealthy` alarms for Node/Spring |
| 10 | Add real unit tests + `terraform fmt -check` in CI |
