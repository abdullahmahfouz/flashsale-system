require "test_helper"

# Oversell test: 200 concurrent checkouts against a product with stock 10.
# Invariants under test (SPEC.md): paid orders <= starting stock, stock never negative.
# Run with DB_POOL=250 so the connection pool is not the bottleneck.
class OversellTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  # Scaffold fixtures (test/fixtures/*.yml) have invalid data (user_id: MyString) and would
  # fail to load; this test builds its own data, so load no fixtures.
  self.fixture_table_names = []

  STARTING_STOCK = 10
  # Default 200 per the task. OVERSELL_THREADS exists only because Postgres in compose has
  # max_connections=100, so 200 simultaneous connections cannot be opened.
  THREADS = Integer(ENV.fetch("OVERSELL_THREADS", 200))

  setup { clean_tables }
  teardown { clean_tables }

  test "200 concurrent checkouts never oversell a product with stock 10" do
    product = Product.create!(name: "Flash Sale Item", stock: STARTING_STOCK)
    mode = ENV["CHECKOUT_MODE"]

    # Warm up autoloading once so threads do not race on constant loading.
    open_session.get "/products/#{product.id}"

    gate = Queue.new
    ready = Queue.new
    results = Queue.new

    threads = Array.new(THREADS) do |i|
      Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection do
          session = open_session # own integration session per thread
          ready << true
          gate.pop # barrier: wait for release
          begin
            session.post "/checkout",
                         params: { product_id: product.id, user_id: i + 1, quantity: 1 },
                         headers: { "Idempotency-Key" => "oversell-key-#{i}-#{SecureRandom.hex(4)}" }
            results << session.response.status
          rescue => e
            results << "EXC #{e.class}"
          end
        end
      end
    end

    THREADS.times { ready.pop }          # all threads are set up and parked
    THREADS.times { gate << :go }        # release them together
    threads.each(&:join)

    statuses = Array.new(results.size) { results.pop }
    counts = statuses.tally.sort_by { |k, _| k.to_s }.to_h
    paid = Order.where(status: "paid").count
    final_stock = product.reload.stock

    puts
    puts "CHECKOUT_MODE=#{mode.inspect} DB_POOL=#{ENV['DB_POOL'].inspect} threads=#{THREADS} starting_stock=#{STARTING_STOCK}"
    puts "responses received: #{statuses.size}"
    puts "HTTP status counts: #{counts.inspect}"
    puts "paid orders: #{paid}"
    puts "final stock: #{final_stock}"

    assert_operator paid, :<=, STARTING_STOCK,
                    "OVERSOLD: #{paid} paid orders for starting stock #{STARTING_STOCK} (status counts: #{counts.inspect})"
    assert_operator final_stock, :>=, 0,
                    "NEGATIVE STOCK: final stock is #{final_stock} (status counts: #{counts.inspect})"
  end

  private

  def clean_tables
    Order.delete_all
    Product.delete_all
  end
end
