/**
 * Node.js Microservice — Placeholder App
 * ---------------------------------------
 * Minimal SQS consumer with a /health endpoint.
 * Replace with real application once the pipeline is validated.
 *
 * Endpoints:
 *   GET  /         → Welcome message
 *   GET  /health   → Health check (JSON with dependency status)
 *   POST /process  → Poll SQS and process one message
 */

const express = require("express");
const { SQSClient, ReceiveMessageCommand, DeleteMessageCommand, GetQueueAttributesCommand } = require("@aws-sdk/client-sqs");

const app = express();
const PORT = process.env.PORT || 8080;
const AWS_REGION = process.env.AWS_REGION || "us-east-1";
const SQS_QUEUE_URL = process.env.SQS_QUEUE_URL || "";

let sqs = null;
if (SQS_QUEUE_URL) {
  sqs = new SQSClient({ region: AWS_REGION });
}

// ── Routes ───────────────────────────────────────────────────

app.get("/", (_req, res) => {
  res.json({
    service: "node-app",
    version: "0.1.0",
    status: "running",
    environment: process.env.NODE_ENV || "dev",
  });
});

app.get("/health", async (_req, res) => {
  const checks = {
    service: "healthy",
    sqs: "unconfigured",
  };

  if (sqs && SQS_QUEUE_URL) {
    try {
      await sqs.send(new GetQueueAttributesCommand({
        QueueUrl: SQS_QUEUE_URL,
        AttributeNames: ["ApproximateNumberOfMessages"],
      }));
      checks.sqs = "healthy";
    } catch (err) {
      checks.sqs = `unhealthy: ${err.message}`;
    }
  }

  const allHealthy = Object.values(checks).every(v => v === "healthy" || v === "unconfigured");
  res.status(allHealthy ? 200 : 503).json(checks);
});

app.post("/process", async (_req, res) => {
  if (!sqs || !SQS_QUEUE_URL) {
    return res.status(503).json({ error: "SQS not configured" });
  }

  try {
    const data = await sqs.send(new ReceiveMessageCommand({
      QueueUrl: SQS_QUEUE_URL,
      MaxNumberOfMessages: 1,
      WaitTimeSeconds: 2,
    }));

    const messages = data.Messages || [];
    if (messages.length === 0) {
      return res.json({ processed: 0, messages: [] });
    }

    const msg = messages[0];
    // Process the message (placeholder)
    const body = JSON.parse(msg.Body);

    // Delete after processing
    await sqs.send(new DeleteMessageCommand({
      QueueUrl: SQS_QUEUE_URL,
      ReceiptHandle: msg.ReceiptHandle,
    }));

    res.json({
      processed: 1,
      message_id: msg.MessageId,
      body,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── Start ────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`node-app listening on port ${PORT}`);
});

module.exports = app; // for testing
