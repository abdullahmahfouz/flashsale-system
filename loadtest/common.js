// Shared helpers for the k6 scenarios. Only real k6 data is written to the summary.
import http from 'k6/http';
import { Counter } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';

export const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';
export const PRODUCT_ID = parseInt(__ENV.PRODUCT_ID || '1', 10);

// 201 / 200 / 409 are expected business outcomes. Only 5xx, 422 and network
// errors count toward http_req_failed.
http.setResponseCallback(http.expectedStatuses(201, 200, 409));

export const c201 = new Counter('checkout_201');
export const c200 = new Counter('checkout_200');
export const c409 = new Counter('checkout_409');
export const cOther = new Counter('checkout_other');

export const summaryTrendStats = ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'];

export function checkout(userId, key) {
  const res = http.post(
    `${BASE_URL}/checkout`,
    JSON.stringify({ product_id: PRODUCT_ID, user_id: userId, quantity: 1 }),
    { headers: { 'Content-Type': 'application/json', 'Idempotency-Key': key } }
  );
  if (res.status === 201) c201.add(1);
  else if (res.status === 200) c200.add(1);
  else if (res.status === 409) c409.add(1);
  else cOther.add(1);
  return res;
}

function val(data, metric, stat) {
  const m = data.metrics[metric];
  if (!m) return null;
  const v = m.values ? m.values : m;
  return v[stat] === undefined ? null : v[stat];
}

export function buildSummary(data, scenario) {
  return {
    scenario,
    p50_ms: val(data, 'http_req_duration', 'med'),
    p95_ms: val(data, 'http_req_duration', 'p(95)'),
    p99_ms: val(data, 'http_req_duration', 'p(99)'),
    req_per_sec: val(data, 'http_reqs', 'rate'),
    total_requests: val(data, 'http_reqs', 'count'),
    error_rate: val(data, 'http_req_failed', 'rate'),
    status_201: val(data, 'checkout_201', 'count') || 0,
    status_200: val(data, 'checkout_200', 'count') || 0,
    status_409: val(data, 'checkout_409', 'count') || 0,
    status_other: val(data, 'checkout_other', 'count') || 0,
  };
}

// handleSummary body shared by all scenarios: normal k6 text summary on stdout
// plus machine-readable JSON at SUMMARY_FILE.
export function makeSummary(data, scenario) {
  const out = {
    stdout: textSummary(data, { indent: ' ', enableColors: false }),
  };
  if (__ENV.SUMMARY_FILE) {
    out[__ENV.SUMMARY_FILE] = JSON.stringify(buildSummary(data, scenario), null, 2);
  }
  return out;
}
