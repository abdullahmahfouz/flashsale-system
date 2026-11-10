-- Usage: psql "$DATABASE_URL" -v starting_stock=1000 -v product_id=1 -X -A -t -f check_invariants.sql
-- Prints one line per SPEC invariant (PASS/FAIL plus the numbers used) and "oversold units".
\set ON_ERROR_STOP on
WITH s AS (
  SELECT (SELECT stock FROM products WHERE id = :product_id)::bigint AS stock_left,
         (SELECT count(*) FROM orders WHERE product_id = :product_id AND status = 'paid')::bigint AS paid,
         :starting_stock::bigint AS starting_stock,
         -- Invariant 4 is trivially true given the UNIQUE index on idempotency_key;
         -- we still count duplicates to confirm the index exists and holds.
         (SELECT count(*) - count(DISTINCT idempotency_key) FROM orders)::bigint AS dup_keys
)
SELECT line FROM (
  SELECT 1 AS n, format('1 %s paid_orders=%s starting_stock=%s (paid <= starting)',
         CASE WHEN paid <= starting_stock THEN 'PASS' ELSE 'FAIL' END, paid, starting_stock) AS line FROM s
  UNION ALL
  SELECT 2, format('2 %s stock_left=%s (stock >= 0)',
         CASE WHEN stock_left >= 0 THEN 'PASS' ELSE 'FAIL' END, stock_left) FROM s
  UNION ALL
  SELECT 3, format('3 %s starting_stock=%s stock_left=%s paid_orders=%s (starting - left = paid; units sold=%s)',
         CASE WHEN starting_stock - stock_left = paid THEN 'PASS' ELSE 'FAIL' END,
         starting_stock, stock_left, paid, starting_stock - stock_left) FROM s
  UNION ALL
  SELECT 4, format('4 %s duplicate_keys=%s', CASE WHEN dup_keys = 0 THEN 'PASS' ELSE 'FAIL' END, dup_keys) FROM s
  UNION ALL
  SELECT 5, format('oversold units=%s', GREATEST(0, paid - starting_stock)) FROM s
) t ORDER BY n;
