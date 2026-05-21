"""
Notification Lambda — Zero-Downtime Pipeline
----------------------------------------------
Triggered by CloudWatch alarms when green environment metrics
breach thresholds. CodeDeploy handles the actual rollback;
this Lambda only publishes a notification event to SNS.

Environment variables (set by Terraform):
  ENVIRONMENT  — dev / staging / prod
  SNS_TOPIC    — ARN of the SNS topic for events
"""

import json
import os
import boto3
from datetime import datetime, timezone

sns = boto3.client("sns")
SNS_TOPIC = os.environ.get("SNS_TOPIC", "")


def handler(event: dict, context) -> dict:
    """CloudWatch Alarm → SNS notification."""

    alarm_name = event.get("alarmName", "unknown")
    alarm_desc = event.get("alarmDescription", "")
    new_state = event.get("newStateValue", "ALARM")
    reason = event.get("newStateReason", "")

    print(f"[NOTIFY] Alarm: {alarm_name} → {new_state}")
    print(f"[NOTIFY] Reason: {reason}")

    if not SNS_TOPIC:
        print("[NOTIFY] SNS topic not configured — skipping publish")
        return {"status": "skipped", "reason": "SNS_TOPIC not set"}

    message = {
        "type": "cloudwatch_alarm",
        "alarm_name": alarm_name,
        "state": new_state,
        "environment": os.environ.get("ENVIRONMENT", "unknown"),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "reason": reason,
    }

    try:
        resp = sns.publish(
            TopicArn=SNS_TOPIC,
            Subject=f"[{os.environ.get('ENVIRONMENT', '')}] Alarm: {alarm_name}",
            Message=json.dumps(message, indent=2),
            MessageAttributes={
                "alarm_name": {
                    "DataType": "String",
                    "StringValue": alarm_name,
                },
                "state": {
                    "DataType": "String",
                    "StringValue": new_state,
                },
            },
        )
        print(f"[NOTIFY] Published to SNS: {resp['MessageId']}")
        return {"status": "published", "message_id": resp["MessageId"]}
    except Exception as exc:
        print(f"[NOTIFY] Failed to publish: {exc}")
        return {"status": "error", "error": str(exc)}
