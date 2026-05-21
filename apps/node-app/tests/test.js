/**
 * Unit tests for the Node.js microservice placeholder.
 */

const { describe, it, before, after } = require("node:test");
const assert = require("assert");
const http = require("http");

// Override SQS env vars before loading app (no SQS in test)
process.env.SQS_QUEUE_URL = "";
process.env.NODE_ENV = "test";

const app = require("../src/index");

function request(method, path, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, "http://localhost:0");
    const opts = {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      method,
      headers: { "Content-Type": "application/json" },
    };

    // app is already listening — use the server address
    const server = app.listen(0, () => {
      const port = server.address().port;
      opts.port = port;

      const req = http.request(opts, (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => {
          server.close();
          resolve({ status: res.statusCode, body: JSON.parse(data || "{}") });
        });
      });
      req.on("error", reject);
      if (body) req.write(JSON.stringify(body));
      req.end();
    });
  });
}

describe("node-app", () => {
  it("GET / returns service info", async () => {
    const res = await request("GET", "/");
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.body.service, "node-app");
    assert.strictEqual(res.body.status, "running");
  });

  it("GET /health returns 200 when SQS is unconfigured", async () => {
    const res = await request("GET", "/health");
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.body.service, "healthy");
    assert.strictEqual(res.body.sqs, "unconfigured");
  });

  it("POST /process returns 503 without SQS config", async () => {
    const res = await request("POST", "/process");
    assert.strictEqual(res.status, 503);
    assert.strictEqual(res.body.error, "SQS not configured");
  });
});
