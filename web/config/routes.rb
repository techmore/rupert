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
  post "/dashboard/customize", to: "home#customize", as: :customize_dashboard

  # ERP modules (registered in ModuleRegistry)
  get "/sales", to: "sales#index", as: :sales
  resources :customers, only: [:index, :show, :new, :create, :edit, :update]
  namespace :projects do
    resources :projects, only: [:index, :show, :new, :create, :edit, :update, :destroy] do
      member { post :transition }
    end
    resources :tasks, only: [:create, :update, :destroy] do
      member { post :transition }
    end
  end
  namespace :goals do
    resources :goals, only: [:index, :show, :new, :create, :edit, :update, :destroy] do
      member { post :transition }
    end
    resources :kpis, only: [:index, :show, :new, :create, :update, :destroy] do
      member { post :reading }
    end
  end
  namespace :sales do
    resources :pos_sessions, only: [:index, :show, :new, :create] do
      member do
        post :refresh
        post :close
        post :reopen
      end
    end
  end

  resources :inventory, only: :index
  resources :inventory_counts do
    member do
      post :submit
      post :approve
      post :reject
      post :reopen
    end
  end
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
  get "/live/sync_status", to: "live#sync_status"

  resource :settings, only: :show do
    get :env, defaults: { format: :json }
    post :env_import, defaults: { format: :json }
    get :env_export
    get :backup
    post :restore, defaults: { format: :json }
    get :drive_status, defaults: { format: :json }
    get :drive_logs, defaults: { format: :json }
    get :drive_auth
    get :drive_oauth_callback
    post :drive_backup, defaults: { format: :json }
    post :drive_disconnect
    post :buzz_generate
    post :buzz_register
    post :buzz_test
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
