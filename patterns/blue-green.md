# Blue/Green Deployment Strategy (AWS ECS Native)

## Context

We use **Amazon ECS native Blue/Green deployments** (2025 feature), which replaces the older AWS CodeDeploy-based approach. This gives us a simpler, built-in deployment model.

## Deployment Lifecycle (6 Phases)

```
┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
│  Phase 1 │──►│  Phase 2 │──►│  Phase 3 │──►│  Phase 4 │──►│  Phase 5 │──►│  Phase 6 │
│ Prepare  │   │  Deploy  │   │   Test   │   │  Shift   │   │ Monitor  │   │ Cleanup  │
└──────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘
```

### 1. Preparation

- Register new ECS task definition (new image tag from ECR).
- Compute difference between current (blue) and desired (green) task sets.
- Validate ALB target group exists for green.

### 2. Deployment

- Launch N green tasks (same count as blue).
- Wait for green tasks to reach `RUNNING` state and pass ECS health checks.
- Green receives **0% production traffic** during this phase.

### 3. Testing

- Run automated smoke tests against green:
  - `GET /health` on each service → must return `200` with `{"status":"healthy"}`.
  - Synthetic transactions through SQS/SNS.
  - RDS connectivity check.
- Validate CloudWatch metrics are being emitted.

### 4. Traffic Shift

- Gradual traffic shift from blue to green via ALB listener rules:
  - **Canary mode**: 10% → 50% → 100% (configurable percentages and intervals).
  - **Linear mode**: traffic shifts in equal increments over N minutes.
- Default for this project: **canary** with 3 steps (10%, 50%, 100%) at 1-minute intervals.

### 5. Monitoring (Bake Time)

- Green runs under full production traffic for **5 minutes** (configurable).
- CloudWatch alarms are actively monitored:
  - `ErrorRate > 5%` → triggers rollback.
  - `p99Latency > 2000ms` → triggers rollback.
  - `ThroughputDropped > 20%` → triggers rollback.
- If no alarms fire, bake passes.

### 6. Cleanup

- Drain connections from blue tasks.
- Terminate blue tasks after drain timeout (30s default).
- Delete old task definition revisions (keep last 5 for rollback).

## Traffic Routing (ALB)

```
                    ┌─────────────┐
                    │     ALB     │
                    │   Listener  │
                    │   :80/:443  │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              ▼            │            ▼
        ┌──────────┐       │      ┌──────────┐
        │  Blue    │       │      │  Green   │
        │  Target  │       │      │  Target  │
        │  Group   │       │      │  Group   │
        └──────────┘       │      └──────────┘
                           │
                    During shift:
                    - Blue weight: 90% → 50% → 0%
                    - Green weight: 10% → 50% → 100%
```

## Terraform Implementation

Key Terraform resources for Blue/Green:

```hcl
# ECS Service with Blue/Green deployment controller
resource "aws_ecs_service" "app" {
  name            = var.service_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "CODE_DEPLOY"  # or "ECS" for native in supported regions
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = "app"
    container_port   = 8080
  }
}

# ALB listener with weighted forwarding
resource "aws_lb_listener_rule" "canary" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 100

  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.blue.arn
        weight = var.blue_weight
      }
      target_group {
        arn    = aws_lb_target_group.green.arn
        weight = var.green_weight
      }
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}
```

## References

- [AWS ECS Blue/Green Deployment Implementation](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/blue-green-deployment-implementation.html)
- [ECS Blue/Green How It Works](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/blue-green-deployment-how-it-works.html)
