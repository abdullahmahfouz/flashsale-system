Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  get "products/:id" => "products#show"
  post "checkout" => "checkout#create"
end
