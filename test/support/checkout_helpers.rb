# Shared helpers for non-transactional checkout tests (real threads, own session per thread).
module CheckoutHelpers
  MODES = %w[naive locked idempotent].freeze
  # Upper bounds so a hung thread fails the test instead of hanging the suite forever.
  SETUP_TIMEOUT = 60  # seconds for all threads to park at the gate
  JOIN_TIMEOUT = 120  # seconds, overall, for all threads to finish after release

  def clean_tables
    Order.delete_all
    Product.delete_all
  end

  def current_mode
    ENV["CHECKOUT_MODE"]
  end

  # nil when CHECKOUT_MODE is one of the three modes, otherwise a failure message.
  def mode_failure
    return nil if MODES.include?(current_mode)
    "CHECKOUT_MODE must be one of #{MODES.inspect}, got #{current_mode.inspect}"
  end

  # The app reads CHECKOUT_MODE on every request, so tests may switch it. Always restored.
  # mode == nil unsets the variable.
  def with_checkout_mode(mode)
    saved = ENV["CHECKOUT_MODE"]
    mode.nil? ? ENV.delete("CHECKOUT_MODE") : ENV["CHECKOUT_MODE"] = mode
    yield
  ensure
    saved.nil? ? ENV.delete("CHECKOUT_MODE") : ENV["CHECKOUT_MODE"] = saved
  end

  def new_key(prefix = "k")
    "#{prefix}-#{SecureRandom.hex(6)}"
  end

  # requests: array of { params: {...}, key: "..." }. Fires all at once behind a gate.
  # Returns array of [status, parsed_body_or_nil], where status is an Integer or a String
  # starting with "EXC" (exception in the request, connection acquisition failure, or hung thread).
  # Cannot deadlock: every thread always signals `ready` (ensure), and every wait/join is bounded.
  def fire_concurrently(requests)
    open_session.get "/products/#{requests.first[:params][:product_id]}" # warm up autoloading
    n = requests.size
    gate = Queue.new
    ready = Queue.new
    slots = Array.new(n)
    lock = Mutex.new

    threads = requests.each_with_index.map do |req, i|
      Thread.new do
        Thread.current.report_on_exception = false
        signalled = false
        begin
          ActiveRecord::Base.connection_pool.with_connection do
            session = open_session
            ready << true
            signalled = true
            gate.pop
            begin
              session.post "/checkout", params: req[:params], headers: { "Idempotency-Key" => req[:key] }
              body = begin
                JSON.parse(session.response.body)
              rescue JSON::ParserError
                nil
              end
              lock.synchronize { slots[i] = [session.response.status, body] }
            rescue => e
              lock.synchronize { slots[i] = ["EXC #{e.class}: #{e.message.to_s[0, 80]}", nil] }
            end
          end
        rescue => e # e.g. connection pool timeout while acquiring
          lock.synchronize { slots[i] ||= ["EXC #{e.class}: #{e.message.to_s[0, 80]}", nil] }
        ensure
          ready << true unless signalled
        end
      end
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SETUP_TIMEOUT
    n.times do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0 || ready.pop(timeout: remaining).nil?
    end
    n.times { gate << :go }

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + JOIN_TIMEOUT
    threads.each do |t|
      remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
      t.kill if t.join(remaining).nil?
    end

    slots.map { |s| s || ["EXC hung or no result (thread timed out)", nil] }
  end

  def post_checkout(params, key)
    headers = key.nil? ? {} : { "Idempotency-Key" => key }
    post "/checkout", params: params, headers: headers
    response.status
  end

  # Sequential request returning [status, parsed_body_or_nil]; an exception becomes ["EXC ...", nil].
  def post_checkout_full(params, key)
    headers = key.nil? ? {} : { "Idempotency-Key" => key }
    post "/checkout", params: params, headers: headers
    body = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      nil
    end
    [response.status, body]
  rescue => e
    ["EXC #{e.class}: #{e.message.to_s[0, 80]}", nil]
  end

  # Statuses that are exceptions or 5xx (never acceptable for 201/200/409/422 flows; 501 is for unknown modes).
  def error_statuses(counts)
    counts.select { |k, _| k.is_a?(String) || k.to_i >= 500 }
  end

  def status_counts(results)
    results.map(&:first).tally.sort_by { |k, _| k.to_s }.to_h
  end
end
