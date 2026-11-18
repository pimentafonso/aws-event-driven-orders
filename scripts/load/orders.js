// Load test for the orders API: places orders at stepped arrival rates.
//
// Usage (see docs/load-test.md for the full procedure):
//   k6 run -e API_ENDPOINT=https://... -e RUN_ID=r1 scripts/load/orders.js
//
// Options, all through -e:
//   RATES          orders per second for each step, default "5,10,20"
//   STEP_SECONDS   length of each step, default 120
//   SUMMARY        file for the JSON summary, default "load-summary.json"
//
// Requests are signed with SigV4 using AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
// and AWS_SESSION_TOKEN from the environment. Every order uses the customer ID
// "load-<RUN_ID>", so scripts/load_check.py can find the run's orders.
// Each step is its own scenario, so the summary reports latency per step.

import http from "k6/http";
import { check } from "k6";
import { Counter } from "k6/metrics";
import { Endpoint, SignatureV4 } from "https://jslib.k6.io/aws/0.11.0/signature.js";
import { textSummary } from "https://jslib.k6.io/k6-summary/0.0.2/index.js";
import { uuidv4 } from "https://jslib.k6.io/k6-utils/1.4.0/index.js";

const ENDPOINT = __ENV.API_ENDPOINT || "";
const RUN_ID = __ENV.RUN_ID || "";
const RATES = (__ENV.RATES || "5,10,20").split(",").map(Number);
const STEP_SECONDS = Number(__ENV.STEP_SECONDS || 120);
const SUMMARY = __ENV.SUMMARY || "load-summary.json";
const SKUS = ["SKU-1", "SKU-2", "SKU-3", "SKU-4", "SKU-5"];

if (!ENDPOINT.startsWith("https://")) throw new Error("set API_ENDPOINT to the https:// API endpoint");
if (!/^[A-Za-z0-9_-]{1,40}$/.test(RUN_ID)) throw new Error("set RUN_ID to 1-40 letters, digits, '-' or '_'");
if (RATES.some((r) => !(r > 0)) || !(STEP_SECONDS > 0)) throw new Error("RATES and STEP_SECONDS must be positive");

const throttled = new Counter("orders_throttled");
const failed = new Counter("orders_failed");

const scenarios = {};
const thresholds = { http_req_failed: ["rate<0.01"] };
RATES.forEach((rate, i) => {
  const name = `step_${i + 1}_${rate}rps`;
  scenarios[name] = {
    executor: "constant-arrival-rate",
    rate,
    timeUnit: "1s",
    duration: `${STEP_SECONDS}s`,
    startTime: `${i * STEP_SECONDS}s`,
    preAllocatedVUs: Math.max(10, rate * 3),
    maxVUs: Math.max(50, rate * 10),
  };
  // A threshold on a scenario's sub-metric makes the summary print it.
  thresholds[`http_req_duration{scenario:${name}}`] = ["p(99)<5000"];
});

export const options = {
  scenarios,
  thresholds,
  summaryTrendStats: ["min", "med", "p(90)", "p(95)", "p(99)", "max"],
  discardResponseBodies: true,
};

const endpoint = new Endpoint(ENDPOINT.replace(/\/+$/, ""));
const signer = new SignatureV4({
  service: "execute-api",
  region: "eu-west-1",
  credentials: {
    accessKeyId: __ENV.AWS_ACCESS_KEY_ID,
    secretAccessKey: __ENV.AWS_SECRET_ACCESS_KEY,
    sessionToken: __ENV.AWS_SESSION_TOKEN,
  },
  uriEscapePath: true,
  applyChecksum: true,
});

export default function () {
  const body = JSON.stringify({
    customer_id: `load-${RUN_ID}`,
    items: [{ sku: SKUS[Math.floor(Math.random() * SKUS.length)], quantity: 1 }],
  });
  const signed = signer.sign({
    method: "POST",
    endpoint,
    path: "/orders",
    headers: { "content-type": "application/json", "idempotency-key": `load-${uuidv4()}` },
    body,
  });
  const response = http.post(signed.url, body, { headers: signed.headers });
  if (response.status === 429) throttled.add(1);
  else if (response.status !== 201) failed.add(1);
  check(response, { "order created (201)": (r) => r.status === 201 });
}

export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: " ", enableColors: false }),
    [SUMMARY]: JSON.stringify(data, null, 2),
  };
}
