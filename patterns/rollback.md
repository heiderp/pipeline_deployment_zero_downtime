# Rollback Strategy

## Overview

CodeDeploy orchestrates Blue/Green deployments and **handles rollback automatically**
when CloudWatch alarms fire during the deployment. No manual intervention is needed.
The notification Lambda sends alerts to Slack/email for visibility.

## Decision Tree

```
Green deployed (CodeDeploy)
            │
            ▼
    ┌───────────────┐
    │ CloudWatch     │
    │ Alarms Active  │
    └───────┬───────┘
            │
   ┌────────┼────────┐
   ▼                 ▼
No alarms ✅      Alarm fires ❌
   │                 │
   ▼                 ▼
Canary continues  CodeDeploy auto-rolls back
Bake completes    ┌────────────────────┐
   │               │ 1. Revert traffic  │
   ▼               │    to blue TGs     │
Cleanup Blue      │ 2. Drain green     │
   │               │    task set        │
   ▼               │ 3. Notify Lambda   │
Success ✅        │    → SNS → Slack   │
                  └────────────────────┘
```

## Rollback Triggers (CloudWatch Alarms)

These alarms are monitored by **CodeDeploy** during deployment. Any alarm
in `ALARM` state triggers an automatic rollback.

| Alarm                 | Threshold                   | Period | Evaluation   |
| --------------------- | --------------------------- | ------ | ------------ |
| `Green-HighErrorRate` | Error rate > 5%             | 1 min  | 3 datapoints |
| `Green-HighLatency`   | p99 latency > 2000ms        | 1 min  | 3 datapoints |
| `Green-LowThroughput` | Request count drops         | 2 min  | 2 datapoints |
| `Green-TaskUnhealthy` | Any task fails health check | 1 min  | 1 datapoint  |

## Rollback Flow (fully automated)

### 1. CloudWatch Alarm Fires

CodeDeploy detects the alarm state change during the canary or bake phase.

### 2. CodeDeploy Auto-Rollback

- **Production traffic** is immediately reverted to the blue task set (original task definition).
- **Green task set** is drained and terminated.
- Deployment status is marked as `STOPPED` or `FAILED`.

### 3. Notification Lambda

- The same alarm that triggered the rollback also invokes the notification Lambda
  via `alarm_actions`.
- Lambda publishes to SNS → can fan out to Slack, email, PagerDuty.
- The Lambda does **not** perform rollback actions — CodeDeploy already did it.

### 4. GitHub Actions `rollback` Job

- The `deploy-green` or `wait-deploy` job fails (CodeDeploy returned non-success).
- The `rollback` job (`if: failure()`) fires and posts a Slack notification with
  deployment context (commit SHA, environment, run link).
- No AWS API calls — CodeDeploy already handled everything.

## Why CodeDeploy + Lambda (two layers)

| Layer                           | Responsibility                                         |
| ------------------------------- | ------------------------------------------------------ |
| **CodeDeploy**                  | Reverts traffic, drains green, marks deployment failed |
| **Lambda**                      | Notifies team via SNS/Slack                            |
| **GitHub Actions rollback job** | Posts deployment-level context (commit, PR, run link)  |

This separation means even if Slack is down, the rollback still happens.

## Terraform: Auto-Rollback Configuration

```hcl
# CodeDeploy deployment group with auto-rollback
resource "aws_codedeploy_deployment_group" "flask" {
  # ...

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }
}

# CloudWatch alarm → Lambda (notification only)
resource "aws_cloudwatch_metric_alarm" "high_error_rate" {
  alarm_name          = "${var.environment}-Green-HighErrorRate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_error_rate_threshold
  alarm_actions       = [aws_lambda_function.notify.arn]  # notify only
  # CodeDeploy monitors this alarm independently — no alarm_actions needed
}

# Lambda permission for CloudWatch
resource "aws_lambda_permission" "cloudwatch" {
  statement_id  = "AllowCloudWatchAlarm"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notify.function_name
  principal     = "lambda.alarms.cloudwatch.amazonaws.com"
}
```

## Notification Format (Slack Example)

```json
{
  "text": "🚨 ROLLBACK TRIGGERED",
  "blocks": [
    {
      "type": "section",
      "text": {
        "text": "*Environment:* staging\n*Service:* flask-app\n*Alarm:* Green-HighErrorRate (7.2%)\n*Action:* CodeDeploy auto-rolled back\n*Commit:* abc1234\n*Run:* <link>"
      }
    }
  ]
}
```

## Testing the Rollback

### Simulated failure

1. Deploy a broken image that fails health checks → CodeDeploy detects unhealthy
   tasks and rolls back.
2. Check CodeDeploy console: deployment status shows `Stopped` with reason.
3. Check CloudWatch logs for the notification Lambda.

### Manual rollback (disaster recovery)

```bash
# Stop an in-progress CodeDeploy deployment
aws deploy stop-deployment --deployment-id d-XXXXXXXXX

# Or force-rollback via ECS (last resort)
aws ecs update-service --cluster dev-cluster --service dev-flask \
  --task-definition <previous-task-def-arn> --force-new-deployment
```

### Verify rollback completed

```bash
# Check ALB traffic is on blue
aws elbv2 describe-rules --listener-arn <prod-listener-arn> \
  --query 'Rules[*].Actions[*].ForwardConfig.TargetGroups[*].Weight'

# Check green tasks are terminated
aws ecs describe-services --cluster dev-cluster --services dev-flask \
  --query 'services[0].taskSets[?status==`DRAINING`]'
```
