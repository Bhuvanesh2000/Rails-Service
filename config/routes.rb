Rails.application.routes.draw do
  resources :surveys, only: [:create, :index]
  
  resources :responses, only: [:create, :show, :update]
  
  get 'responses/user/:user_id/survey/:survey_id', to: 'responses#user_responses'
end
