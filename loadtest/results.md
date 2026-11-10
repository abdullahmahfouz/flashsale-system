# Load test results

Setup: laptop, single Puma process (WEB_CONCURRENCY=0, RAILS_MAX_THREADS=16, DB_POOL=100), Rails in
`production` env (logs at warn level to a file), Postgres 16 and Redis in Docker, k6 on the same machine.
Puma on one laptop is the bottleneck, so absolute numbers are only comparable across modes in this setup.
Dedicated DB `flashsale_system_loadtest`; every run deletes all orders and resets product 1 stock to the
starting stock (default 1000). Latencies are http_req_duration in ms. Error rate is http_req_failed
(5xx, 422, network failures; 201/200/409 are treated as expected). "oversold" = max(0, paid - starting stock).

| date | mode | scenario | start stock | p50 ms | p95 ms | p99 ms | req/s | error rate | 201 | 200 | 409 | other | orders in DB | stock left | oversold | invariants |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-11-09 14:59:32 | naive | spike | 1000 | 266.6 | 798.27 | 889.06 | 1590.46 | 0 | 2707 | 0 | 29522 | 0 | 2707 | 0 | 1707 | 1 FAIL, 2 PASS, 3 FAIL, 4 PASS |
| 2026-11-09 15:00:30 | locked | spike | 1000 | 428.2 | 734.86 | 1334.35 | 1059.93 | 0 | 1000 | 0 | 20637 | 0 | 1000 | 0 | 0 | 1 PASS, 2 PASS, 3 PASS, 4 PASS |
| 2026-11-09 15:01:20 | idempotent | spike | 1000 | 548.96 | 987.05 | 1297.09 | 840 | 0 | 1000 | 0 | 16229 | 0 | 1000 | 0 | 0 | 1 PASS, 2 PASS, 3 PASS, 4 PASS |
| 2026-11-09 15:02:17 | naive | retry-storm | 1000 | 105.07 | 139.08 | 462.66 | 1653.6 | 0.041813314081159944 | 1 | 0 | 31852 | 1390 | 1 | 0 | 0 | 1 PASS, 2 PASS, 3 FAIL, 4 PASS |
| 2026-11-09 15:02:41 | locked | retry-storm | 1000 | 502.29 | 522.58 | 527.18 | 396.93 | 0 | 1 | 0 | 8133 | 0 | 1 | 999 | 0 | 1 PASS, 2 PASS, 3 PASS, 4 PASS |
| 2026-11-09 15:03:06 | idempotent | retry-storm | 1000 | 117.77 | 121.26 | 124.13 | 1686.6 | 0 | 1 | 33924 | 0 | 0 | 1 | 999 | 0 | 1 PASS, 2 PASS, 3 PASS, 4 PASS |
