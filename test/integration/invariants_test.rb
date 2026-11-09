require "test_helper"
require_relative "../support/checkout_helpers"

# All four SPEC invariants under 200 concurrent checkouts, stock 10.
# Every invariant is evaluated independently; failures are collected, then reported together.
#
# Expected per mode: naive FAILS (deliberate "before" demonstration: it violates the invariants
# under concurrency); locked and idempotent PASS.
# Note on (d): all keys here are unique, so "duplicate keys" is vacuous on its own (the UNIQUE
# index also guarantees it). The reconciliation and exact-count checks below are what give this test
# teeth: they fail on all-409 / all-422 / all-501 runs where nothing was actually sold.
class InvariantsTest < ActionDispatch::IntegrationTest
  include CheckoutHelpers
  self.use_transactional_tests = false

  STARTING_STOCK = 10
  THREADS = Integer(ENV.fetch("OVERSELL_THREADS", 200))

  setup { clean_tables }
  teardown { clean_tables }

  test "all four SPEC invariants hold under 200 concurrent checkouts" do
    product = Product.create!(name: "Invariant Item", stock: STARTING_STOCK)
    requests = Array.new(THREADS) do |i|
      { params: { product_id: product.id, user_id: i + 1, quantity: 1 },
        key: "inv-key-#{i}-#{SecureRandom.hex(4)}" }
    end

    results = fire_concurrently(requests)
    counts = status_counts(results)
    paid = Order.where(status: "paid").count
    final_stock = product.reload.stock
    keys = Order.pluck(:idempotency_key)
    dup_keys = keys.tally.select { |_, n| n > 1 }
    mode = current_mode

    puts
    puts "[invariants] CHECKOUT_MODE=#{mode.inspect} threads=#{THREADS} starting_stock=#{STARTING_STOCK}"
    puts "[invariants] responses: #{results.size}, status counts: #{counts.inspect}"
    puts "[invariants] paid orders: #{paid}, final stock: #{final_stock}, total orders: #{keys.size}, duplicate keys: #{dup_keys.size}"

    failures = []
    failures << "(mode) #{mode_failure}" if mode_failure
    failures << "(a) paid orders #{paid} > starting stock #{STARTING_STOCK}" unless paid <= STARTING_STOCK
    failures << "(b) stock negative: #{final_stock}" unless final_stock >= 0
    unless STARTING_STOCK - final_stock == paid
      failures << "(c) starting stock - stock left = #{STARTING_STOCK - final_stock}, but paid orders = #{paid}"
    end
    failures << "(d) duplicate idempotency keys among orders: #{dup_keys.inspect}" unless dup_keys.empty?
    errs = error_statuses(counts)
    failures << "(extra) exceptions/5xx/501 responses seen: #{errs.inspect}" unless errs.empty?
    failures << "(reconcile) 201 responses #{counts[201].to_i} != paid orders #{paid}" unless counts[201].to_i == paid
    failures << "(reconcile) responses #{results.size} != requests #{THREADS}" unless results.size == THREADS
    if %w[locked idempotent].include?(mode)
      failures << "(exact) #{mode}: 201 count #{counts[201].to_i}, expected exactly #{STARTING_STOCK}" unless counts[201].to_i == STARTING_STOCK
      failures << "(exact) #{mode}: paid #{paid}, stock left #{final_stock}, expected #{STARTING_STOCK} and 0" unless paid == STARTING_STOCK && final_stock == 0
    end

    assert failures.empty?, "Invariant violations (#{failures.size}) status counts #{counts.inspect}:\n  " + failures.join("\n  ")
  end
end
