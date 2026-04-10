require "sidekiq/web"
Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      get "requests/:id", to: "requests#show"
      post "requests", to: "requests#create"
      post "requests/:id/cancel", to: "requests#cancel"
    end
  end

  mount Sidekiq::Web => "/sidekiq"
end
