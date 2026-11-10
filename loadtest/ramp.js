// Ramp: 0 -> 500 VUs over 30s, unique user_id and key per iteration.
import { checkout, makeSummary, summaryTrendStats as sts } from './common.js';

export const options = {
  stages: [{ duration: '30s', target: 500 }],
  summaryTrendStats: sts,
};

const RUN = `${Date.now()}-${Math.floor(Math.random() * 1e9)}`;

export default function () {
  const userId = __VU * 1000000 + __ITER + 1;
  checkout(userId, `ramp-${RUN}-${__VU}-${__ITER}`);
}

export function handleSummary(data) {
  return makeSummary(data, 'ramp');
}
