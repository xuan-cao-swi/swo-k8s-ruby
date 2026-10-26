Rails.application.routes.draw do
  root "demo#index"

  get "health" => "rails/health#show", as: :rails_health_check

  resources :items, only: %i[index show create]

  get "slow"     => "demo#slow"
  get "external" => "demo#external"
  get "error"    => "demo#error"
  get "trace"    => "demo#trace"
end
