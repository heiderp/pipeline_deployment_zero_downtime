"""
Flask Monolith — Placeholder App
---------------------------------
Minimal "hello world" API that integrates with SQS, SNS, and RDS.
Replace with real application once the pipeline is validated.

Endpoints:
  GET  /              → Welcome message
  GET  /health        → Health check (returns JSON with dependency status)
  POST /events        → Publish an event to SNS
  GET  /tasks         → Receive a message from SQS
"""

import os
import json
import boto3
from flask import Flask, jsonify, request, g
from datetime import datetime

app = Flask(__name__)

# ── Configuration ────────────────────────────────────────────

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
SNS_TOPIC_ARN = os.getenv("SNS_TOPIC_ARN", "")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///:memory:")

# ── AWS Clients (lazy init) ──────────────────────────────────

def get_sns():
    if "sns" not in g:
        g.sns = boto3.client("sns", region_name=AWS_REGION) if SNS_TOPIC_ARN else None
    return g.sns

def get_sqs():
    if "sqs" not in g:
        g.sqs = boto3.client("sqs", region_name=AWS_REGION) if SQS_QUEUE_URL else None
    return g.sqs

# ── Routes ───────────────────────────────────────────────────

@app.route("/")
def index():
    return jsonify({
        "service": "flask-app",
        "version": "0.1.0",
        "status": "running",
        "environment": os.getenv("ENVIRONMENT", "dev"),
    })

@app.route("/health")
def health():
    """Health check endpoint. Returns 200 if all dependencies are reachable."""
    checks = {
        "service": "healthy",
        "sns": "unconfigured",
        "sqs": "unconfigured",
        "database": "unconfigured",
    }

    # Check SNS connectivity
    if SNS_TOPIC_ARN:
        try:
            sns = get_sns()
            sns.get_topic_attributes(TopicArn=SNS_TOPIC_ARN)
            checks["sns"] = "healthy"
        except Exception as e:
            checks["sns"] = f"unhealthy: {str(e)}"

    # Check SQS connectivity
    if SQS_QUEUE_URL:
        try:
            sqs = get_sqs()
            sqs.get_queue_attributes(QueueUrl=SQS_QUEUE_URL, AttributeNames=["ApproximateNumberOfMessages"])
            checks["sqs"] = "healthy"
        except Exception as e:
            checks["sqs"] = f"unhealthy: {str(e)}"

    # Check database connectivity
    if "sqlite" not in DATABASE_URL:
        try:
            import sqlite3
            conn = sqlite3.connect(":memory:")
            conn.execute("SELECT 1")
            conn.close()
            checks["database"] = "healthy"
        except Exception as e:
            checks["database"] = f"unhealthy: {str(e)}"
    else:
        checks["database"] = "healthy"

    all_healthy = all(v == "healthy" or v == "unconfigured" for v in checks.values())
    status = 200 if all_healthy else 503

    return jsonify(checks), status

@app.route("/events", methods=["POST"])
def publish_event():
    """Publish an event to SNS."""
    if not SNS_TOPIC_ARN:
        return jsonify({"error": "SNS not configured"}), 503

    data = request.get_json(silent=True) or {}
    message = data.get("message", "hello from flask")
    message_id = "mock-id"

    try:
        sns = get_sns()
        if sns:
            resp = sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Message=json.dumps({"message": message, "timestamp": datetime.utcnow().isoformat()}),
                MessageAttributes={
                    "source": {"DataType": "String", "StringValue": "flask-app"}
                }
            )
            message_id = resp.get("MessageId", "sent")
    except Exception as e:
        return jsonify({"error": str(e)}), 500

    return jsonify({"message_id": message_id, "message": message}), 201

@app.route("/tasks", methods=["GET"])
def receive_tasks():
    """Receive a message from SQS (long poll)."""
    if not SQS_QUEUE_URL:
        return jsonify({"error": "SQS not configured"}), 503

    try:
        sqs = get_sqs()
        if sqs:
            resp = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=2,
            )
            messages = resp.get("Messages", [])
            if messages:
                msg = messages[0]
                return jsonify({
                    "message_id": msg["MessageId"],
                    "body": json.loads(msg["Body"]),
                    "receipt_handle": msg["ReceiptHandle"],
                })
    except Exception as e:
        return jsonify({"error": str(e)}), 500

    return jsonify({"messages": []}), 200

# ── Entrypoint ───────────────────────────────────────────────

if __name__ == "__main__":
    port = int(os.getenv("PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)
