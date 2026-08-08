# frozen_string_literal: true

Rails.application.routes.draw do
  root to: "home#index"

  get "/login", to: "sessions#new", as: :login
  post "/login", to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout

  get "/setup", to: "setup#new", as: :setup
  post "/setup", to: "setup#create"

  get "/onboarding", to: "onboarding#index", as: :onboarding

  resources :tenants, only: [:index, :new, :create]

  scope path: :api, format: :json do
    namespace :webhooks do
      post "/app_uninstalled", to: "app_uninstalled#receive"
      post "/app_scopes_update", to: "app_scopes_update#receive"
      post "/customers_data_request", to: "customers_data_request#receive"
      post "/customers_redact", to: "customers_redact#receive"
      post "/shop_redact", to: "shop_redact#receive"
    end
  end

  mount ShopifyApp::Engine, at: "/api"

  get "/dashboard", to: "home#index"
  resources :inventory, only: :index
  resources :reconcile, only: :index do
    collection do
      post :policy
      post :apply
    end
  end
  resources :ledger, only: :index
  resources :alerts, only: :index do
    collection do
      post :update_status
    end
  end
  resources :syncs, only: [:index, :create] do
    collection do
      post :source
    end
  end

  resource :settings, only: :show do
    get :env, defaults: { format: :json }
    post :env_import, defaults: { format: :json }
    get :env_export
    get :backup
    post :restore, defaults: { format: :json }
  end

  get "/warehouse", to: "warehouse#index", as: :warehouse
  post "/warehouse/tiers", to: "warehouse#update_tiers", as: :update_warehouse_tiers
  resources :warehouse_shares, only: [:create, :show, :update, :destroy] do
    member do
      post :update_tiers
    end
  end

  get "/w/:token", to: "warehouse_sales#show", as: :warehouse_sale

  # Any other routes just render the app
  match "*path" => "home#index", via: [:get, :post]
end
