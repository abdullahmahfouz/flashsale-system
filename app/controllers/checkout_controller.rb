class CheckoutController < ApplicationController
  def create
    mode = ENV["CHECKOUT_MODE"]
    unless mode == "naive"
      return render json: { error: "CHECKOUT_MODE '#{mode}' not implemented" }, status: :not_implemented
    end

    key = request.headers["Idempotency-Key"].presence
    product_id = positive_int(params[:product_id])
    user_id = positive_int(params[:user_id])
    quantity = positive_int(params[:quantity])
    unless key && product_id && user_id && quantity
      return render json: { error: "invalid input" }, status: :unprocessable_entity
    end

    product = Product.find_by(id: product_id)
    return render json: { error: "invalid product_id" }, status: :unprocessable_entity unless product

    # naive: read, check, write, no transaction, no lock
    return render json: { error: "sold out" }, status: :conflict unless product.stock > 0

    product.update_columns(stock: product.stock - 1)
    order = Order.create!(product_id: product.id, user_id: user_id, quantity: quantity,
                          status: "paid", idempotency_key: key)
    render json: order, status: :created
  end

  private

  def positive_int(value)
    return nil unless value.to_s.match?(/\A\d+\z/)
    n = value.to_s.to_i
    n.positive? ? n : nil
  end
end
