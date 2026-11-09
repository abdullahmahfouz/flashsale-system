require "test_helper"
require_relative "../support/checkout_helpers"

# Same Idempotency-Key sent 5 times concurrently: one order, one 201, four 200s, stock decremented once.
# Only the `idempotent` mode is expected to satisfy the replay (200) tests per SPEC: in naive and
# locked mode these are EXPECTED to fail (naive: unique index error; locked: 409 duplicate key).
class IdempotencyTest < ActionDispatch::IntegrationTest
  include CheckoutHelpers
  self.use_transactional_tests = false

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

  test "sequential replay: 201 then 200 with the same order id and body, one order, one decrement" do
    product = Product.create!(name: "Replay Item", stock: 5)
    key = new_key("replay")
    params = { product_id: product.id, user_id: 9, quantity: 1 }
    s1, b1 = post_checkout_full(params, key)
    s2, b2 = post_checkout_full(params, key)
    puts "\n[replay] CHECKOUT_MODE=#{current_mode.inspect} first=#{s1.inspect} second=#{s2.inspect} stock=#{product.reload.stock} orders=#{Order.count}"

    failures = []
    failures << "first status #{s1.inspect}, expected 201" unless s1 == 201
    failures << "replay status #{s2.inspect}, expected 200" unless s2 == 200
    failures << "replay body #{b2.inspect} != original #{b1.inspect}" unless b1.present? && b1 == b2
    failures << "orders with key = #{Order.where(idempotency_key: key).count}, expected 1" unless Order.where(idempotency_key: key).count == 1
    failures << "stock = #{product.reload.stock}, expected 4" unless product.reload.stock == 4
    assert failures.empty?, "Replay failures:\n  " + failures.join("\n  ")
  end

  # Per SPEC a 409 (sold out) creates no order, so the key is not "used". A replay is therefore
  # processed again from scratch; while still sold out it yields 409 again and creates no order.
  # This holds in every mode (sold out is checked the same way), so it is not idempotent-only.
  test "replay after a 409 sold-out is processed again: 409 again, no order, stock unchanged" do
    product = Product.create!(name: "Sold Out Item", stock: 1)
    assert_equal 201, post_checkout({ product_id: product.id, user_id: 1, quantity: 1 }, new_key("first"))
    key = new_key("after409")
    params = { product_id: product.id, user_id: 2, quantity: 1 }
    s1, b1 = post_checkout_full(params, key)
    s2, b2 = post_checkout_full(params, key)
    puts "\n[replay-after-409] CHECKOUT_MODE=#{current_mode.inspect} first=#{s1.inspect} #{b1.inspect} replay=#{s2.inspect} #{b2.inspect} orders=#{Order.count} stock=#{product.reload.stock}"

    failures = []
    failures << "first attempt status #{s1.inspect}, expected 409" unless s1 == 409
    failures << "replay status #{s2.inspect}, expected 409" unless s2 == 409
    failures << "order exists for the 409'd key" if Order.exists?(idempotency_key: key)
    failures << "orders = #{Order.count}, expected 1" unless Order.count == 1
    failures << "stock = #{product.reload.stock}, expected 0" unless product.reload.stock == 0
    assert failures.empty?, "Replay-after-409 failures:\n  " + failures.join("\n  ")
  end

  # Best-effort race test for the RecordNotUnique path (idempotent mode). The same key is sent
  # concurrently for two DIFFERENT products (different row locks, so the requests do not serialize on
  # the product lock and can both pass the pre-check and both reach the INSERT; the loser then blocks
  # on the unique index and gets RecordNotUnique). I CANNOT force or observe that interleaving from
  # here: the test cannot tell whether a 422 came from the pre-check path or the RecordNotUnique path.
  # What it asserts is the SPEC outcome whichever path ran: per key exactly one order, exactly one
  # decrement across both products, one 201 and one 422 (200 is impossible: payloads differ), no 5xx.
  ROUNDS = 30
  test "same key on two different products raced #{ROUNDS} times: one order, one decrement, 201 + 422" do
    a = Product.create!(name: "Race A", stock: ROUNDS)
    b = Product.create!(name: "Race B", stock: ROUNDS)
    keys = Array.new(ROUNDS) { |r| "race-#{r}-#{SecureRandom.hex(4)}" }
    all_statuses = []
    per_round_bad = []
    keys.each_with_index do |key, r|
      results = fire_concurrently([
        { params: { product_id: a.id, user_id: 1, quantity: 1 }, key: key },
        { params: { product_id: b.id, user_id: 1, quantity: 1 }, key: key }
      ])
      st = results.map(&:first)
      all_statuses.concat(st)
      per_round_bad << "round #{r}: statuses #{st.inspect}, expected one 201 and one 422" unless st.sort_by(&:to_s) == [201, 422]
    end
    counts = all_statuses.tally.sort_by { |k, _| k.to_s }.to_h
    decrements = (a.reload.stock - ROUNDS).abs + (b.reload.stock - ROUNDS).abs
    orders_per_key = keys.map { |k| Order.where(idempotency_key: k).count }
    puts "\n[race] CHECKOUT_MODE=#{current_mode.inspect} rounds=#{ROUNDS} status counts: #{counts.inspect} (observed 200 count: #{counts[200].to_i}, 422 count: #{counts[422].to_i})"
    puts "[race] total decrements across both products: #{decrements}, orders: #{Order.count}, keys with != 1 order: #{orders_per_key.count { |c| c != 1 }}"
    puts "[race] note: cannot tell which path (pre-check vs RecordNotUnique rescue) produced each 422"

    failures = per_round_bad.dup
    failures << "total decrements #{decrements}, expected #{ROUNDS} (one per key)" unless decrements == ROUNDS
    failures << "orders per key #{orders_per_key.tally.inspect}, expected all 1" unless orders_per_key.all? { |c| c == 1 }
    failures << "total orders #{Order.count}, expected #{ROUNDS}" unless Order.count == ROUNDS
    errs = error_statuses(counts)
    failures << "exceptions/5xx seen: #{errs.inspect}" unless errs.empty?
    unexpected = counts.keys - [201, 200, 422]
    failures << "statuses outside {201,200,422}: #{unexpected.inspect}" unless unexpected.empty?
    assert failures.empty?, "Race failures (#{failures.size}):\n  " + failures.first(10).join("\n  ")
  end
end
