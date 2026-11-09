require "test_helper"
require_relative "../support/checkout_helpers"

# Same Idempotency-Key sent 5 times concurrently: one order, one 201, four 200s, stock decremented once.
# Only the `idempotent` mode is expected to satisfy this per SPEC.
class IdempotencyTest < ActionDispatch::IntegrationTest
  include CheckoutHelpers
  self.use_transactional_tests = false
  self.fixture_table_names = []

  setup { clean_tables }
  teardown { clean_tables }

  test "same key sent 5 times concurrently yields one order, one 201, four 200s, one decrement" do
    product = Product.create!(name: "Idem Item", stock: 10)
    key = "idem-key-#{SecureRandom.hex(6)}"
    requests = Array.new(5) { { params: { product_id: product.id, user_id: 42, quantity: 1 }, key: key } }

    results = fire_concurrently(requests)
    statuses = results.map(&:first)
    counts = statuses.tally.sort_by { |k, _| k.to_s }.to_h
    orders = Order.where(idempotency_key: key)
    returned_ids = results.map { |_, body| body && body["id"] }
    stock = product.reload.stock

    puts
    puts "[idempotency] CHECKOUT_MODE=#{ENV['CHECKOUT_MODE'].inspect} status counts: #{counts.inspect}"
    puts "[idempotency] orders with key: #{orders.count}, returned order ids: #{returned_ids.inspect}, stock: 10 -> #{stock}"

    failures = []
    failures << "orders with key = #{orders.count}, expected 1" unless orders.count == 1
    failures << "201 count = #{statuses.count(201)}, expected 1" unless statuses.count(201) == 1
    failures << "200 count = #{statuses.count(200)}, expected 4" unless statuses.count(200) == 4
    failures << "all responses should reference one order id, got #{returned_ids.inspect}" unless returned_ids.uniq.size == 1 && orders.count == 1 && returned_ids.first == orders.first&.id
    failures << "stock = #{stock}, expected 9 (decremented exactly once)" unless stock == 9
    assert failures.empty?, "Idempotency failures:\n  " + failures.join("\n  ")
  end
end
