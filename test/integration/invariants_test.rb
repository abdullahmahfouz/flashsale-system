require "test_helper"
require_relative "../support/checkout_helpers"

# All four SPEC invariants under 200 concurrent checkouts, stock 10.
# Every invariant is evaluated independently; failures are collected, then reported together.
class InvariantsTest < ActionDispatch::IntegrationTest
  include CheckoutHelpers
  self.use_transactional_tests = false
  self.fixture_table_names = []

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
    counts = results.map(&:first).tally.sort_by { |k, _| k.to_s }.to_h
    paid = Order.where(status: "paid").count
    final_stock = product.reload.stock
    keys = Order.pluck(:idempotency_key)
    dup_keys = keys.tally.select { |_, n| n > 1 }

    puts
    puts "[invariants] CHECKOUT_MODE=#{ENV['CHECKOUT_MODE'].inspect} threads=#{THREADS} starting_stock=#{STARTING_STOCK}"
    puts "[invariants] responses: #{results.size}, status counts: #{counts.inspect}"
    puts "[invariants] paid orders: #{paid}, final stock: #{final_stock}, total orders: #{keys.size}, duplicate keys: #{dup_keys.size}"

    failures = []
    failures << "(a) paid orders #{paid} > starting stock #{STARTING_STOCK}" unless paid <= STARTING_STOCK
    failures << "(b) stock negative: #{final_stock}" unless final_stock >= 0
    unless STARTING_STOCK - final_stock == paid
      failures << "(c) starting stock - stock left = #{STARTING_STOCK - final_stock}, but paid orders = #{paid}"
    end
    failures << "(d) duplicate idempotency keys among orders: #{dup_keys.inspect}" unless dup_keys.empty?
    errors = counts.keys.select { |k| k.is_a?(String) || k.to_i >= 500 }
    failures << "(extra) exceptions/5xx responses seen: #{counts.slice(*errors).inspect}" unless errors.empty?

    assert failures.empty?, "Invariant violations (#{failures.size}):\n  " + failures.join("\n  ")
  end
end
