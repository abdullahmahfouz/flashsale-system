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
    quantity = exactly_one(params[:quantity])
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
  # quantity is validated to be exactly 1, so stock drops by 1 per order and
  # "starting stock - stock left = paid orders" (SPEC invariant 3) holds.
  def locked_checkout(key, product_id, user_id, quantity, idempotent:)
    if idempotent
      existing = Order.find_by(idempotency_key: key)
      return render_replay(existing, product_id, user_id, quantity) if existing
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

    render_locked_result(result, product_id, user_id, quantity)
  rescue ActiveRecord::RecordNotUnique
    # Transaction already rolled back (stock decrement included).
    unless idempotent
      return render json: { error: "duplicate Idempotency-Key" }, status: :conflict
    end
    existing = Order.find_by!(idempotency_key: key)
    render_replay(existing, product_id, user_id, quantity)
  end

  def render_locked_result(result, product_id, user_id, quantity)
    kind, order = result
    case kind
    when :invalid_product then render json: { error: "invalid product_id" }, status: :unprocessable_entity
    when :sold_out then render json: { error: "sold out" }, status: :conflict
    when :duplicate then render_replay(order, product_id, user_id, quantity)
    when :created then render json: order, status: :created
    end
  end

  def positive_int(value)
    return nil unless value.to_s.match?(/\A\d+\z/)
    n = value.to_s.to_i
    n.positive? ? n : nil
  end

  def same_payload?(order, product_id, user_id, quantity)
    order.product_id == product_id && order.user_id == user_id && order.quantity == quantity
  end

  def render_replay(order, product_id, user_id, quantity)
    if same_payload?(order, product_id, user_id, quantity)
      render json: order, status: :ok
    else
      render json: { error: "Idempotency-Key reused with a different payload" }, status: :unprocessable_entity
    end
  end

  # SPEC clarification: quantity must be exactly 1.
  def exactly_one(value)
    return nil unless value.is_a?(String) || value.is_a?(Integer)
    value.to_s == "1" ? 1 : nil
  end
end
