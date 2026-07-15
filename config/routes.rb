Rails.application.routes.draw do
  get "healthz" => "health#show"
  get "readyz" => "readiness#show"

  namespace :v1 do
    get "search" => "searches#show"
    get "search_requests/:id" => "search_requests#show"
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
end
