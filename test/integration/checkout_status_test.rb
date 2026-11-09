require "test_helper"
require_relative "../support/checkout_helpers"

# Sequential status-code tests: 409 sold out, 422 validation, basic 201.
class CheckoutStatusTest < ActionDispatch::IntegrationTest
  include CheckoutHelpers
  self.use_transactional_tests = false
  self.fixture_table_names = []

  setup { clean_tables }
  teardown { clean_tables }

  test "409 when sold out: no order created, stock unchanged" do
    product = Product.create!(name: "Last One", stock: 1)
    assert_equal 201, post_checkout({ product_id: product.id, user_id: 1, quantity: 1 }, "so-1-#{SecureRandom.hex(4)}")
    assert_equal 0, product.reload.stock
    orders_before = Order.count

    status = post_checkout({ product_id: product.id, user_id: 2, quantity: 1 }, "so-2-#{SecureRandom.hex(4)}")
    puts "\n[sold-out] CHECKOUT_MODE=#{ENV['CHECKOUT_MODE'].inspect} status after exhaustion: #{status}, orders #{orders_before} -> #{Order.count}, stock #{product.reload.stock}"
    assert_equal 409, status
    assert_equal orders_before, Order.count
    assert_equal 0, product.reload.stock
  end

  test "422 for invalid input" do
    product = Product.create!(name: "Valid Item", stock: 5)
    good = { product_id: product.id, user_id: 1, quantity: 1 }
    key = -> { "val-#{SecureRandom.hex(4)}" }
    cases = {
      "missing Idempotency-Key" => [good, nil],
      "blank Idempotency-Key" => [good, ""],
      "missing product_id" => [good.except(:product_id), key.call],
      "non-existent product_id" => [good.merge(product_id: product.id + 100_000), key.call],
      "non-integer product_id" => [good.merge(product_id: "abc"), key.call],
      "missing user_id" => [good.except(:user_id), key.call],
      "invalid user_id" => [good.merge(user_id: "abc"), key.call],
      "missing quantity" => [good.except(:quantity), key.call],
      "quantity 0" => [good.merge(quantity: 0), key.call],
      "quantity negative" => [good.merge(quantity: -1), key.call],
      "quantity non-integer (1.5)" => [good.merge(quantity: "1.5"), key.call],
      "quantity non-integer (abc)" => [good.merge(quantity: "abc"), key.call]
    }
    observed = cases.transform_values { |(params, k)| post_checkout(params, k) }
    puts "\n[validation] CHECKOUT_MODE=#{ENV['CHECKOUT_MODE'].inspect} observed: #{observed.inspect}"
    bad = observed.reject { |_, s| s == 422 }
    assert_empty bad, "Expected 422 for all; got: #{bad.inspect}"
    assert_equal 0, Order.count, "no order should be created for invalid input"
    assert_equal 5, product.reload.stock
  end

  test "201 for a valid checkout creates a paid order and decrements stock" do
    product = Product.create!(name: "Happy Path", stock: 3)
    status = post_checkout({ product_id: product.id, user_id: 7, quantity: 1 }, "ok-#{SecureRandom.hex(4)}")
    assert_equal 201, status
    assert_equal 1, Order.where(status: "paid").count
    assert_equal 2, product.reload.stock
  end
end
