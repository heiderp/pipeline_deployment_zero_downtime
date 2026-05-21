"""
Rollback Lambda — Zero-Downtime Pipeline
------------------------------------------
Triggered by CloudWatch alarms when the green environment fails
health validation during a Blue/Green deployment.

Actions:
  1. Revert ALB listener rules to 100% blue / 0% green for all services.
  2. Drain green ECS tasks (set desired count to 0).
  3. (Optional) Publish rollback notification event.

Expected environment variables (set by Terraform):
  ENVIRONMENT              — dev / staging / prod
  FLASK_RULE_ARN           — ALB listener rule ARN for Flask service
  NODE_RULE_ARN            — ALB listener rule ARN for Node service
  SPRING_RULE_ARN          — ALB listener rule ARN for Spring service
  FLASK_BLUE_TG_ARN        — Blue target group ARN for Flask
  FLASK_GREEN_TG_ARN       — Green target group ARN for Flask
  NODE_BLUE_TG_ARN         — ...
  NODE_GREEN_TG_ARN        — ...
  SPRING_BLUE_TG_ARN       — ...
  SPRING_GREEN_TG_ARN      — ...
  CLUSTER_NAME             — ECS cluster name
  FLASK_SERVICE            — ECS service name for Flask
  NODE_SERVICE             — ECS service name for Node
  SPRING_SERVICE           — ECS service name for Spring
"""

import json
import os
import boto3
from datetime import datetime, timezone

elbv2 = boto3.client("elbv2")
ecs = boto3.client("ecs")


def revert_listener_rule(rule_arn: str, blue_tg_arn: str, green_tg_arn: str) -> dict:
    """Set ALB listener rule to 100% blue, 0% green."""
    return elbv2.modify_rule(
        RuleArn=rule_arn,
        Actions=[
            {
                "Type": "forward",
                "ForwardConfig": {
                    "TargetGroups": [
                        {"TargetGroupArn": blue_tg_arn, "Weight": 100},
                        {"TargetGroupArn": green_tg_arn, "Weight": 0},
                    ]
                },
            }
        ],
    )


def drain_service(cluster: str, service: str) -> dict:
    """Set ECS service desired count to 0 (drain green tasks)."""
    return ecs.update_service(
        cluster=cluster,
        service=service,
        desiredCount=0,
    )


def handler(event: dict, context) -> dict:
    """
    CloudWatch Alarm → Lambda trigger.

    Event structure:
    {
      "alarmData": {
        "alarmName": "dev-Green-HighErrorRate",
        "state": { "value": "ALARM" },
        ...
      }
    }

    Or SNS-wrapped:
    {
      "Records": [{
        "Sns": {
          "Message": "{\"alarmName\": \"...\", \"newStateValue\": \"ALARM\"}"
        }
      }]
    }
    """

    # Parse alarm name from event
    alarm_name = "unknown"

    if "alarmData" in event:
        alarm_name = event["alarmData"].get("alarmName", "unknown")
    elif "Records" in event and len(event["Records"]) > 0:
        sns_msg = json.loads(event["Records"][0]["Sns"]["Message"])
        alarm_name = sns_msg.get("alarmName", "unknown")
    elif "alarmName" in event:
        alarm_name = event["alarmName"]

    print(f"[ROLLBACK] Alarm triggered: {alarm_name}")
    print(f"[ROLLBACK] Environment: {os.environ.get('ENVIRONMENT', 'unknown')}")

    results = {
        "alarm": alarm_name,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "actions": [],
        "errors": [],
    }

    # ── Per-service rollback ─────────────────────────────────

    services = [
        {
            "name": "flask",
            "rule_arn": os.environ.get("FLASK_RULE_ARN"),
            "blue_tg": os.environ.get("FLASK_BLUE_TG_ARN"),
            "green_tg": os.environ.get("FLASK_GREEN_TG_ARN"),
            "service": os.environ.get("FLASK_SERVICE"),
        },
        {
            "name": "node",
            "rule_arn": os.environ.get("NODE_RULE_ARN"),
            "blue_tg": os.environ.get("NODE_BLUE_TG_ARN"),
            "green_tg": os.environ.get("NODE_GREEN_TG_ARN"),
            "service": os.environ.get("NODE_SERVICE"),
        },
        {
            "name": "spring",
            "rule_arn": os.environ.get("SPRING_RULE_ARN"),
            "blue_tg": os.environ.get("SPRING_BLUE_TG_ARN"),
            "green_tg": os.environ.get("SPRING_GREEN_TG_ARN"),
            "service": os.environ.get("SPRING_SERVICE"),
        },
    ]

    cluster = os.environ.get("CLUSTER_NAME", "")

    for svc in services:
        # Revert traffic to blue
        if svc["rule_arn"] and svc["blue_tg"] and svc["green_tg"]:
            try:
                revert_listener_rule(svc["rule_arn"], svc["blue_tg"], svc["green_tg"])
                results["actions"].append(f"reverted {svc['name']} traffic to blue")
                print(f"[ROLLBACK] {svc['name']}: traffic reverted to blue")
            except Exception as exc:
                msg = f"Failed to revert {svc['name']} listener rule: {exc}"
                results["errors"].append(msg)
                print(f"[ROLLBACK] ERROR: {msg}")
        else:
            print(f"[ROLLBACK] {svc['name']}: missing config, skipping")

        # Drain green tasks
        if svc["service"] and cluster:
            try:
                drain_service(cluster, svc["service"])
                results["actions"].append(f"drained {svc['name']} green tasks")
                print(f"[ROLLBACK] {svc['name']}: green tasks draining")
            except Exception as exc:
                msg = f"Failed to drain {svc['name']} tasks: {exc}"
                results["errors"].append(msg)
                print(f"[ROLLBACK] ERROR: {msg}")

    status = "success" if not results["errors"] else "partial_failure"
    results["status"] = status

    print(f"[ROLLBACK] Complete. Status: {status}")
    return results
