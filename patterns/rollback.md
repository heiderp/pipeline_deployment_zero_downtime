# Rollback Strategy

## Overview

If the green environment fails health validation, the pipeline **automatically reverts** traffic to the blue environment. No manual approval is needed — speed is critical to preserving availability.

## Decision Tree

```
Green deployed and receiving traffic
            │
            ▼
    ┌───────────────┐
    │ Health Check   │
    │ Monitoring     │
    └───────┬───────┘
            │
   ┌────────┼────────┐
   ▼                 ▼
Pass ✅           Fail ❌
   │                 │
   ▼                 ▼
Continue         Rollback
Cleanup          Triggered
```

## Rollback Triggers (CloudWatch Alarms)

| Alarm                 | Threshold                         | Period | Evaluation   |
| --------------------- | --------------------------------- | ------ | ------------ |
| `Green-HighErrorRate` | Error rate > 5%                   | 1 min  | 3 datapoints |
| `Green-HighLatency`   | p99 latency > 2000ms              | 1 min  | 3 datapoints |
| `Green-LowThroughput` | Throughput drop > 20% vs baseline | 2 min  | 2 datapoints |
| `Green-TaskUnhealthy` | Any task fails health check       | 1 min  | 1 datapoint  |

## Rollback Actions (in order)

### 1. Notify Team

Immediately post to Slack/email with:

- Service name and environment.
- Reason for rollback (which alarm fired, current metric value).
- Link to CloudWatch dashboard and logs.
- Commit SHA that was being deployed.

### 2. Revert Traffic to Blue

- Lambda function calls ECS API to update ALB listener rules:
  - Blue target group weight → 100%.
  - Green target group weight → 0%.
- **No new deployment happens** — the existing blue tasks are still running and healthy.

### 3. Drain and Terminate Green

- Stop sending new connections to green tasks (drain mode, 30s timeout).
- Decrease green desired count to 0 (terminate tasks).

### 4. Tag Commit as Failed

- `git tag` the commit as `rollback-<timestamp>`.
- Create a GitHub issue with rollback details for post-mortem.

## Terraform: Rollback Lambda

```hcl
resource "aws_lambda_function" "rollback" {
  filename      = "lambda/rollback.zip"
  function_name = "${var.environment}-ecs-rollback"
  role          = aws_iam_role.rollback_lambda.arn
  handler       = "index.handler"
  runtime       = "python3.11"

  environment {
    variables = {
      CLUSTER_NAME    = aws_ecs_cluster.main.name
      SERVICE_NAME    = aws_ecs_service.app.name
      BLUE_TG_ARN     = aws_lb_target_group.blue.arn
      GREEN_TG_ARN    = aws_lb_target_group.green.arn
      SLACK_WEBHOOK   = var.slack_webhook_url
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "high_error_rate" {
  alarm_name          = "${var.environment}-Green-HighErrorRate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_actions       = [aws_lambda_function.rollback.arn]
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
        "text": "*Environment:* staging\n*Service:* flask-app\n*Alarm:* Green-HighErrorRate (7.2%)\n*Commit:* abc1234\n*Dashboard:* <link>"
      }
    }
  ]
}
```

## Testing the Rollback

- The pipeline includes a **smoke test** phase that intentionally fails if health endpoints don't respond.
- For disaster recovery testing: trigger a rollback manually via AWS Console or CLI to verify the Lambda works.
- Post-mortem: every rollback generates a GitHub issue with the incident timeline.
