class ProductsController < ApplicationController
  def show
    product = Product.find(params[:id])
    render json: product.as_json(only: %i[id name stock])
  end
end
