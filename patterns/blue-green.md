# Blue/Green Deployment Strategy (AWS CodeDeploy)

## Context

We use **AWS CodeDeploy** to orchestrate Blue/Green deployments on ECS.
CodeDeploy handles the entire deployment lifecycle — from launching the
green task set through canary traffic shifting, bake time monitoring, and
final cleanup — with automatic rollback if CloudWatch alarms fire.

This replaces the earlier "manual rolling update" approach. The GitHub Actions
workflow only triggers the deployment and waits for CodeDeploy to finish.

## Deployment Lifecycle (CodeDeploy handles all 6 phases)

```
┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
│  Phase 1 │──►│  Phase 2 │──►│  Phase 3 │──►│  Phase 4 │──►│  Phase 5 │──►│  Phase 6 │
│ Prepare  │   │  Deploy  │   │   Test   │   │  Shift   │   │ Monitor  │   │ Cleanup  │
│ (GH Actions)│(CodeDeploy)│ (test ALB) │  (Canary)  │  (Bake)   │  (Drain)  │
└──────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘
```

### 1. Preparation (GitHub Actions)
- GitHub Actions registers the new task definition with the updated ECR image tag.
- Creates a CodeDeploy deployment referencing the new revision.
- Passes the deployment ID to the wait step.

### 2. Deployment (CodeDeploy)
- CodeDeploy creates a new (green) task set with the updated task definition.
- Green tasks are registered with the **test listener** target groups (port 8081).
- Production traffic (port 80) continues flowing to blue tasks.
- Green tasks start and pass ELB health checks on the test listener.

### 3. Testing (via test listener)
- While green runs behind the test listener, it can be validated independently:
  - `curl http://<alb>:8081/` → green-only traffic.
  - Smoke tests, integration tests, manual verification.
- The GitHub Actions `health-check` job tests via the production listener after CodeDeploy succeeds.

### 4. Traffic Shift (Canary, CodeDeploy-managed)
- CodeDeploy gradually shifts production traffic from blue to green:
  - **Canary mode** (`ECSCanary10Percent5Minutes`): 10% every 5 minutes.
  - Configurable via `deployment_config_name` in Terraform.
- The ALB's production listener (port 80) is updated automatically by CodeDeploy.
- Path-based routing rules (`/flask/*`, `/node/*`, `/spring/*`) are preserved.

### 5. Monitoring (Bake Time)
- Green runs under full production traffic.
- CloudWatch alarms are actively monitored by **CodeDeploy**:
  - Any alarm firing → CodeDeploy **automatically rolls back** (no human needed).
  - Alarms also trigger a notification Lambda → SNS → Slack/email.
- Bake time is built into the canary intervals (5 minutes per step × 10 steps = 50 min max).

### 6. Cleanup
- CodeDeploy drains connections from blue tasks.
- Old blue task set is scaled to 0 and terminated.
- The green task set becomes the new blue for the next deployment.

## Traffic Routing (ALB + CodeDeploy)

```
                         ┌─────────────────────┐
                         │        ALB          │
                         │                     │
                         │  Prod Listener :80  │──► Blue TG (active)
                         │  /flask/*           │
                         │  /node/*            │
                         │  /spring/*          │
                         │                     │
                         │  Test Listener :8081│──► Green TG (validation only)
                         └─────────────────────┘
                                  │
                    CodeDeploy swaps target groups
                    between prod and test listeners
                    during deployment.
```

## Per-Service Configuration

Each service has its own Blue/Green target group pair and CodeDeploy deployment group:

| Service | Blue TG | Green TG | Deployment Group |
|---------|---------|----------|-----------------|
| Flask   | `dev-flask-blue` | `dev-flask-green` | `dev-flask` |
| Node    | `dev-node-blue`  | `dev-node-green`  | `dev-node`  |
| Spring  | `dev-spring-blue`| `dev-spring-green`| `dev-spring` |

All 3 deployment groups belong to the same CodeDeploy application (`dev-app`).

## Terraform Implementation

```hcl
# ECS Service with CODE_DEPLOY controller
resource "aws_ecs_service" "flask" {
  name            = "${var.environment}-flask"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.flask.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.flask_blue.arn
    container_name   = "flask-app"
    container_port   = 8080
  }
}

# CodeDeploy application
resource "aws_codedeploy_app" "main" {
  name             = "${var.environment}-app"
  compute_platform = "ECS"
}

# CodeDeploy deployment group (one per service)
resource "aws_codedeploy_deployment_group" "flask" {
  app_name               = aws_codedeploy_app.main.name
  deployment_group_name  = "${var.environment}-flask"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.flask.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.main.arn]
      }
      test_traffic_route {
        listener_arns = [aws_lb_listener.test.arn]
      }
      target_group {
        name = aws_lb_target_group.flask_blue.name
      }
      target_group {
        name = aws_lb_target_group.flask_green.name
      }
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }
}
```

## GitHub Actions Integration

The workflow no longer handles traffic shifting, baking, or cleanup:

```yaml
# Old approach (rolling update, manual shift): 15 jobs
# New approach (CodeDeploy): 8 jobs

# deploy-green job creates a CodeDeploy deployment:
aws deploy create-deployment \
  --application-name "${ENV}-app" \
  --deployment-group-name "${ENV}-flask" \
  --revision "revisionType=AppSpecContent,..."

# wait-deploy job polls CodeDeploy:
aws deploy wait deployment-successful --deployment-id "$DEPLOY_ID"

# health-check job validates production endpoints (post-deploy smoke test)
# rollback job only notifies Slack (CodeDeploy already reverted traffic)
```

## Canary Configuration Options

| Config Name | Traffic Pattern | Total Time |
|-------------|----------------|------------|
| `ECSCanary10Percent5Minutes` | 10% every 5 min | ~50 min |
| `ECSCanary10Percent15Minutes` | 10% every 15 min | ~150 min |
| `CodeDeployDefault.ECSLinear10PercentEvery1Minutes` | 10% every 1 min | ~10 min |
| `CodeDeployDefault.ECSLinear10PercentEvery3Minutes` | 10% every 3 min | ~30 min |

**Default for this project**: `ECSCanary10Percent5Minutes` (safe for PoC, can be
shortened to `ECSLinear10PercentEvery1Minutes` for faster demo cycles).

## References

- [AWS CodeDeploy ECS Blue/Green](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployment-steps-ecs.html)
- [CodeDeploy AppSpec for ECS](https://docs.aws.amazon.com/codedeploy/latest/userguide/reference-appspec-file-structure-hooks.html#appspec-hooks-ecs)
