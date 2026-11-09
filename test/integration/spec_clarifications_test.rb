require "test_helper"
require_relative "../support/checkout_helpers"

# Tests for the SPEC "Clarifications" section (C1 quantity, C2 replayed key + different payload,
# C4 locked duplicate key) plus unknown-mode 501 and per-request mode switching.
# All tests are non-transactional with manual cleanup (Orders then Products).
#
# Mode awareness: tests labelled "(current mode)" follow the CHECKOUT_MODE the suite runs under and
# assert what SPEC says for that mode. Others force their mode with with_checkout_mode (restored in
# ensure), which is legitimate because the app reads CHECKOUT_MODE on every request.
class SpecClarificationsTest < ActionDispatch::IntegrationTest
  include CheckoutHelpers
  self.use_transactional_tests = false

  setup { clean_tables }
  teardown { clean_tables }

  # ---- C1: quantity must be exactly 1 ----------------------------------------------------------

  test "C1: quantity 5 -> 422, no order, stock unchanged, in every mode" do
    product = Product.create!(name: "C1 Item", stock: 5)
    failures = []
    observed = {}
    MODES.each do |m|
      with_checkout_mode(m) do
        status, = post_checkout_full({ product_id: product.id, user_id: 1, quantity: 5 }, new_key("c1"))
        observed[m] = status
        failures << "#{m}: status #{status.inspect}, expected 422" unless status == 422
      end
    end
    puts "\n[C1] observed quantity=5 statuses: #{observed.inspect}, orders=#{Order.count}, stock=#{product.reload.stock}"
    failures << "orders created: #{Order.count}" unless Order.count == 0
    failures << "stock changed to #{product.reload.stock}, expected 5" unless product.reload.stock == 5
    assert failures.empty?, "C1 failures:\n  " + failures.join("\n  ")
  end

  # Observed app behavior (not assumed): form-encoded params are always strings, so "1" is the normal
  # case; JSON integer 1 and JSON string "1" are both accepted by the app.
  test "quantity '1' as string (form), integer 1 (JSON) and string '1' (JSON): observed app behavior is 201 each" do
    product = Product.create!(name: "Qty Item", stock: 20)
    observed = {}
    MODES.each do |m|
      with_checkout_mode(m) do
        observed["#{m} form '1'"] = post_checkout({ product_id: product.id, user_id: 1, quantity: "1" }, new_key("q"))
        [1, "1"].each do |q|
          post "/checkout", params: { product_id: product.id, user_id: 1, quantity: q }.to_json,
                            headers: { "Content-Type" => "application/json", "Idempotency-Key" => new_key("q") }
          observed["#{m} json #{q.inspect}"] = response.status
        end
      end
    end
    puts "\n[quantity-forms] observed: #{observed.inspect}"
    bad = observed.reject { |_, s| s == 201 }
    assert_empty bad, "expected 201 for each (observed behavior), got #{bad.inspect}"
    assert_equal 9, Order.count
    assert_equal 11, product.reload.stock
  end

  # ---- Unknown / unset mode -> 501; mode read per request ----------------------------------------

  test "unknown, empty or unset CHECKOUT_MODE -> 501 with error body, nothing written" do
    product = Product.create!(name: "Mode Item", stock: 5)
    observed = {}
    [nil, "", "bogus", "NAIVE"].each do |m|
      with_checkout_mode(m) do
        status, body = post_checkout_full({ product_id: product.id, user_id: 1, quantity: 1 }, new_key("m"))
        observed[m.inspect] = [status, body]
      end
    end
    puts "\n[unknown-mode] observed: #{observed.inspect}"
    bad = observed.reject { |_, (s, b)| s == 501 && b.is_a?(Hash) && b["error"].present? }
    assert_empty bad, "expected 501 with an error body, got #{bad.inspect}"
    assert_equal 0, Order.count
    assert_equal 5, product.reload.stock
  end

  test "mode is read per request: the same replayed key behaves differently as ENV switches between requests" do
    product = Product.create!(name: "Switch Item", stock: 10)
    key = new_key("switch")
    params = { product_id: product.id, user_id: 3, quantity: 1 }
    r = {}
    with_checkout_mode("idempotent") { r[:first_idempotent] = post_checkout_full(params, key) }
    with_checkout_mode("idempotent") { r[:replay_idempotent] = post_checkout_full(params, key) }
    with_checkout_mode("locked") { r[:replay_locked] = post_checkout_full(params, key) }
    with_checkout_mode("naive") { r[:replay_naive] = post_checkout_full(params, key) }
    with_checkout_mode("idempotent") { r[:replay_idempotent_again] = post_checkout_full(params, key) }
    puts "\n[mode-switch] observed: #{r.inspect}; orders=#{Order.count}"

    failures = []
    failures << "first (idempotent) #{r[:first_idempotent][0].inspect}, expected 201" unless r[:first_idempotent][0] == 201
    failures << "replay (idempotent) #{r[:replay_idempotent][0].inspect}, expected 200" unless r[:replay_idempotent][0] == 200
    unless r[:replay_locked][0] == 409 && r[:replay_locked][1].is_a?(Hash) && r[:replay_locked][1]["error"] == "duplicate Idempotency-Key"
      failures << "replay (locked) #{r[:replay_locked].inspect}, expected 409 duplicate Idempotency-Key"
    end
    naive_status = r[:replay_naive][0]
    naive_failed = naive_status.is_a?(String) ? naive_status.include?("RecordNotUnique") : naive_status >= 500
    failures << "replay (naive) #{naive_status.inspect}, expected an exception (RecordNotUnique) or 5xx" unless naive_failed
    failures << "replay (idempotent again) #{r[:replay_idempotent_again][0].inspect}, expected 200" unless r[:replay_idempotent_again][0] == 200
    failures << "orders = #{Order.count}, expected 1" unless Order.count == 1
    assert failures.empty?, "Mode switching failures:\n  " + failures.join("\n  ")
  end

  # ---- C4: locked duplicate key -----------------------------------------------------------------

  test "C4 (locked): same key twice sequentially -> 201 then 409 duplicate Idempotency-Key, one order, one decrement" do
    with_checkout_mode("locked") do
      product = Product.create!(name: "C4 Item", stock: 5)
      key = new_key("c4")
      params = { product_id: product.id, user_id: 1, quantity: 1 }
      s1, = post_checkout_full(params, key)
      s2, b2 = post_checkout_full(params, key)
      puts "\n[C4] first=#{s1.inspect} second=#{s2.inspect} #{b2.inspect} orders=#{Order.count} stock=#{product.reload.stock}"
      failures = []
      failures << "first status #{s1.inspect}, expected 201" unless s1 == 201
      failures << "second status #{s2.inspect}, expected 409" unless s2 == 409
      failures << "second body #{b2.inspect}, expected error 'duplicate Idempotency-Key'" unless b2.is_a?(Hash) && b2["error"] == "duplicate Idempotency-Key"
      failures << "orders with key = #{Order.where(idempotency_key: key).count}, expected 1" unless Order.where(idempotency_key: key).count == 1
      failures << "stock = #{product.reload.stock}, expected 4 (decremented once; duplicate rolled back)" unless product.reload.stock == 4
      assert failures.empty?, "C4 failures:\n  " + failures.join("\n  ")
    end
  end

  # ---- C2: replayed key, different payload (current mode) ------------------------------------------

  # Setup: key K used by user 1 on product P1 (201). Then replay K with: same payload; different
  # product_id; different user_id. Expected per SPEC for the CURRENT mode:
  #   idempotent: same -> 200 same order; different product / user -> 422; nothing written.
  #   locked:     every duplicate -> 409 "duplicate Idempotency-Key"; one order; stock decremented once overall.
  #   naive:      no handling; the second request fails (anything but 2xx); exactly one order exists.
  #               Naive stock is observed and printed only (SPEC does not define it).
  def c2_scenario
    p1 = Product.create!(name: "C2 P1", stock: 5)
    p2 = Product.create!(name: "C2 P2", stock: 5)
    key = new_key("c2")
    first, = post_checkout_full({ product_id: p1.id, user_id: 1, quantity: 1 }, key)
    raise "setup request did not return 201: #{first.inspect}" unless first == 201
    original = Order.find_by!(idempotency_key: key)
    [p1, p2, key, original]
  end

  def assert_c2(label, variant_params, expect_replay_ok: false)
    failures = []
    failures << mode_failure if mode_failure
    p1, p2, key, original = c2_scenario
    params = variant_params.call(p1, p2)
    status, body = post_checkout_full(params, key)
    s1, s2 = p1.reload.stock, p2.reload.stock
    puts "\n[C2 #{label}] CHECKOUT_MODE=#{current_mode.inspect} status=#{status.inspect} body=#{body.inspect} orders=#{Order.count} stock P1=#{s1} P2=#{s2}"

    case current_mode
    when "idempotent"
      if expect_replay_ok
        failures << "status #{status.inspect}, expected 200" unless status == 200
        failures << "body #{body.inspect}, expected original order id #{original.id}" unless body.is_a?(Hash) && body["id"] == original.id
      else
        failures << "status #{status.inspect}, expected 422" unless status == 422
      end
      failures << "orders = #{Order.count}, expected 1 (nothing written)" unless Order.count == 1
      failures << "stock P1=#{s1} P2=#{s2}, expected 4 and 5 (no change by the replay)" unless s1 == 4 && s2 == 5
    when "locked"
      failures << "status #{status.inspect}, expected 409" unless status == 409
      failures << "body #{body.inspect}, expected error 'duplicate Idempotency-Key'" unless body.is_a?(Hash) && body["error"] == "duplicate Idempotency-Key"
      failures << "orders = #{Order.count}, expected 1" unless Order.count == 1
      failures << "total stock #{s1 + s2}, expected 9 (decremented exactly once overall)" unless s1 + s2 == 9
    when "naive"
      # Observed: the unique-index violation propagates as an exception out of the request (RecordNotUnique).
      # A rendered 5xx would also count as "the request fails".
      failed = status.is_a?(String) ? status.include?("RecordNotUnique") : status >= 500
      failures << "status #{status.inspect}, expected an exception (RecordNotUnique) or 5xx" unless failed
      failures << "orders = #{Order.count}, expected exactly 1" unless Order.count == 1
    end
    assert failures.empty?, "C2 #{label} failures (mode #{current_mode.inspect}):\n  " + failures.join("\n  ")
  end

  test "C2 (current mode): same key, same payload" do
    assert_c2("same payload", ->(p1, _p2) { { product_id: p1.id, user_id: 1, quantity: 1 } }, expect_replay_ok: true)
  end

  test "C2 (current mode): same key, different product_id" do
    assert_c2("different product", ->(_p1, p2) { { product_id: p2.id, user_id: 1, quantity: 1 } })
  end

  test "C2 (current mode): same key, different user_id" do
    assert_c2("different user", ->(p1, _p2) { { product_id: p1.id, user_id: 2, quantity: 1 } })
  end
end
