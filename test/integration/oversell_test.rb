require "test_helper"
require_relative "../support/checkout_helpers"

# Oversell test: 200 concurrent checkouts against a product with stock 10.
# Invariants under test (SPEC.md): paid orders <= starting stock, stock never negative.
# Run with DB_POOL=250 so the connection pool is not the bottleneck.
#
# Expected per mode: naive FAILS (that is the deliberate "before" demonstration: oversell and/or
# the exactness checks); locked and idempotent PASS (10 x 201, 190 x 409).
# Every assertion is evaluated; failures are collected and asserted once at the end.
class OversellTest < ActionDispatch::IntegrationTest
  include CheckoutHelpers
  self.use_transactional_tests = false

  STARTING_STOCK = 10
  # Default 200 per the task. OVERSELL_THREADS is kept only because Postgres in compose may have a low
  # max_connections; the exact 10 x 201 / 190 x 409 check below is derived from THREADS, so it stays
  # correct for any override.
  THREADS = Integer(ENV.fetch("OVERSELL_THREADS", 200))

  setup { clean_tables }
  teardown { clean_tables }

  test "200 concurrent checkouts never oversell a product with stock 10" do
    product = Product.create!(name: "Flash Sale Item", stock: STARTING_STOCK)
    mode = current_mode

    requests = Array.new(THREADS) do |i|
      { params: { product_id: product.id, user_id: i + 1, quantity: 1 },
        key: "oversell-key-#{i}-#{SecureRandom.hex(4)}" }
    end
    results = fire_concurrently(requests)
    counts = status_counts(results)
    paid = Order.where(status: "paid").count
    final_stock = product.reload.stock

    puts
    puts "[oversell] CHECKOUT_MODE=#{mode.inspect} DB_POOL=#{ENV['DB_POOL'].inspect} threads=#{THREADS} starting_stock=#{STARTING_STOCK}"
    puts "[oversell] responses received: #{results.size}"
    puts "[oversell] HTTP status counts: #{counts.inspect}"
    puts "[oversell] paid orders: #{paid}"
    puts "[oversell] final stock: #{final_stock}"

    failures = []
    failures << mode_failure if mode_failure
    failures << "OVERSOLD: #{paid} paid orders for starting stock #{STARTING_STOCK}" unless paid <= STARTING_STOCK
    failures << "NEGATIVE STOCK: final stock is #{final_stock}" unless final_stock >= 0
    failures << "responses received #{results.size}, expected #{THREADS}" unless results.size == THREADS
    errs = error_statuses(counts)
    failures << "exceptions/5xx/501 statuses seen: #{errs.inspect}" unless errs.empty?
    failures << "201 count #{counts[201].to_i} != paid orders #{paid}" unless counts[201].to_i == paid
    if %w[locked idempotent].include?(mode)
      failures << "#{mode}: paid #{paid}, expected starting stock #{STARTING_STOCK}" unless paid == STARTING_STOCK
      failures << "#{mode}: 201 count #{counts[201].to_i}, expected #{STARTING_STOCK}" unless counts[201].to_i == STARTING_STOCK
      failures << "#{mode}: 409 count #{counts[409].to_i}, expected #{THREADS - STARTING_STOCK}" unless counts[409].to_i == THREADS - STARTING_STOCK
    end
    assert failures.empty?, "Oversell test failures (#{failures.size}) status counts #{counts.inspect}:\n  " + failures.join("\n  ")
  end
end
