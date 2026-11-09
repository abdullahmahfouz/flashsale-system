class CheckoutController < ApplicationController
  MODES = %w[naive locked idempotent].freeze

  def create
    mode = ENV["CHECKOUT_MODE"]
    unless MODES.include?(mode)
      return render json: { error: "CHECKOUT_MODE '#{mode}' not implemented" }, status: :not_implemented
    end

    key = request.headers["Idempotency-Key"].presence
    product_id = positive_int(params[:product_id])
    user_id = positive_int(params[:user_id])
    quantity = positive_int(params[:quantity])
    unless key && product_id && user_id && quantity
      return render json: { error: "invalid input" }, status: :unprocessable_entity
    end

    case mode
    when "naive" then naive_checkout(key, product_id, user_id, quantity)
    when "locked" then locked_checkout(key, product_id, user_id, quantity, idempotent: false)
    when "idempotent" then locked_checkout(key, product_id, user_id, quantity, idempotent: true)
    end
  end

  private

  def naive_checkout(key, product_id, user_id, quantity)
    product = Product.find_by(id: product_id)
    return render json: { error: "invalid product_id" }, status: :unprocessable_entity unless product

    # naive: read, check, write, no transaction, no lock
    return render json: { error: "sold out" }, status: :conflict unless product.stock > 0

    product.update_columns(stock: product.stock - 1)
    order = Order.create!(product_id: product.id, user_id: user_id, quantity: quantity,
                          status: "paid", idempotency_key: key)
    render json: order, status: :created
  end

  # locked: transaction + SELECT ... FOR UPDATE. idempotent adds key handling.
  # Stock is decremented by 1 per order (same as naive), so
  # "starting stock - stock left = paid orders" (SPEC invariant 3) holds.
  def locked_checkout(key, product_id, user_id, quantity, idempotent:)
    if idempotent
      existing = Order.find_by(idempotency_key: key)
      return render json: existing, status: :ok if existing
    end

    result = nil
    ActiveRecord::Base.transaction do
      product = Product.lock.find_by(id: product_id)
      if product.nil?
        result = [:invalid_product]
        next
      end

      if idempotent
        # A duplicate that waited on the row lock sees the winner's order here,
        # before anything is decremented.
        existing = Order.find_by(idempotency_key: key)
        if existing
          result = [:duplicate, existing]
          next
        end
      end

      if product.stock <= 0
        result = [:sold_out]
        next
      end

      product.update!(stock: product.stock - 1)
      order = Order.create!(product_id: product.id, user_id: user_id, quantity: quantity,
                            status: "paid", idempotency_key: key)
      result = [:created, order]
    end

    render_locked_result(result)
  rescue ActiveRecord::RecordNotUnique
    # Transaction already rolled back (stock decrement included).
    raise unless idempotent
    existing = Order.find_by!(idempotency_key: key)
    render json: existing, status: :ok
  end

  def render_locked_result(result)
    kind, order = result
    case kind
    when :invalid_product then render json: { error: "invalid product_id" }, status: :unprocessable_entity
    when :sold_out then render json: { error: "sold out" }, status: :conflict
    when :duplicate then render json: order, status: :ok
    when :created then render json: order, status: :created
    end
  end

  def positive_int(value)
    return nil unless value.to_s.match?(/\A\d+\z/)
    n = value.to_s.to_i
    n.positive? ? n : nil
  end
end
