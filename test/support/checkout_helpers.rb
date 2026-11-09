# Shared helpers for non-transactional checkout tests (real threads, own session per thread).
module CheckoutHelpers
  def clean_tables
    Order.delete_all
    Product.delete_all
  end

  # requests: array of { params: {...}, key: "..." }. Fires all at once behind a gate.
  # Returns array of [status, parsed_body_or_nil] (or "EXC ..." strings as status).
  def fire_concurrently(requests)
    open_session.get "/products/#{requests.first[:params][:product_id]}" # warm up autoloading
    gate = Queue.new
    ready = Queue.new
    results = Queue.new

    threads = requests.map do |req|
      Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection do
          session = open_session
          ready << true
          gate.pop
          begin
            session.post "/checkout", params: req[:params], headers: { "Idempotency-Key" => req[:key] }
            body = begin
              JSON.parse(session.response.body)
            rescue JSON::ParserError
              nil
            end
            results << [session.response.status, body]
          rescue => e
            results << ["EXC #{e.class}", nil]
          end
        end
      end
    end

    requests.size.times { ready.pop }
    requests.size.times { gate << :go }
    threads.each(&:join)
    Array.new(results.size) { results.pop }
  end

  def post_checkout(params, key)
    headers = key.nil? ? {} : { "Idempotency-Key" => key }
    post "/checkout", params: params, headers: headers
    response.status
  end
end
