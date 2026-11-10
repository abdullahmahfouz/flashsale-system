// Retry storm: many VUs POST the SAME Idempotency-Key and payload for a fixed
// duration. The key must create at most one order.
import { checkout, makeSummary, summaryTrendStats as sts } from './common.js';

export const options = {
  vus: 200,
  duration: '20s',
  summaryTrendStats: sts,
};

// NOTE: the key MUST come from env (set once by run.sh). Computing it in script
// scope would give every VU its own key, because each VU has a separate JS runtime.
const KEY = __ENV.STORM_KEY;
if (!KEY) throw new Error('STORM_KEY env var is required');

export default function () {
  checkout(777, KEY);
}

export function handleSummary(data) {
  return makeSummary(data, 'retry-storm');
}
