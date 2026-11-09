require "test_helper"
require_relative "../support/checkout_helpers"

# GET /products/:id (mode-independent).
class ProductsTest < ActionDispatch::IntegrationTest
  include CheckoutHelpers
  self.use_transactional_tests = false

  setup { clean_tables }
  teardown { clean_tables }

  test "GET /products/:id returns 200 with id, name and current stock" do
    product = Product.create!(name: "Shown Item", stock: 7)
    get "/products/#{product.id}"
    body = JSON.parse(response.body)
    assert_equal 200, response.status
    assert_equal product.id, body["id"]
    assert_equal "Shown Item", body["name"]
    assert_equal 7, body["stock"]
  end

  test "GET /products/:id reflects stock after a checkout" do
    product = Product.create!(name: "Shown Item", stock: 3)
    assert_equal 201, post_checkout({ product_id: product.id, user_id: 1, quantity: 1 }, new_key) if MODES.include?(current_mode)
    get "/products/#{product.id}"
    assert_equal 200, response.status
    assert_equal product.reload.stock, JSON.parse(response.body)["stock"]
  end

  test "GET /products/:id returns 404 for an unknown id" do
    get "/products/#{Product.maximum(:id).to_i + 100_000}"
    assert_equal 404, response.status
  end
end
