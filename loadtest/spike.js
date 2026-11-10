// Spike: 500 VUs for 20s, unique user_id and Idempotency-Key per iteration.
import { checkout, makeSummary, summaryTrendStats as sts } from './common.js';

export const options = {
  vus: 500,
  duration: '20s',
  summaryTrendStats: sts,
};

const RUN = `${Date.now()}-${Math.floor(Math.random() * 1e9)}`;

export default function () {
  const userId = __VU * 1000000 + __ITER + 1;
  checkout(userId, `spike-${RUN}-${__VU}-${__ITER}`);
}

export function handleSummary(data) {
  return makeSummary(data, 'spike');
}
