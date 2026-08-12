# frozen_string_literal: true

Rails.application.routes.draw do
  root to: "home#index"

  get "/login", to: "sessions#new", as: :login
  post "/login", to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout

  get "/auth/google", to: "oauth#authorize", as: :google_auth
  get "/auth/google/callback", to: "oauth#callback", as: :google_callback

  get "/setup", to: "setup#new", as: :setup
  post "/setup", to: "setup#create"

  get "/onboarding", to: "onboarding#index", as: :onboarding

  resources :tenants, only: [:index, :new, :create]

  resources :users, only: [:index, :new, :create, :edit, :update, :destroy] do
    member do
      post :deactivate
      post :activate
      post :update_permissions
    end
  end
  resource :permissions, only: :show do
    post :save
    post :reset
  end

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

  get "/search", to: "search#index", as: :search
  get "/dashboard", to: "home#index"
  post "/dashboard/customize", to: "home#customize", as: :customize_dashboard

  # ERP modules (registered in ModuleRegistry)
  get "/sales", to: "sales#index", as: :sales
  get "/sales/print", to: "sales#print", as: :sales_print
  resources :orders, only: [:show] do
    member do
      post :add_tracking
      post :update_fulfillment_status
      post :refund
    end
  end
  resources :customers, only: [:index, :show, :new, :create, :edit, :update]
  namespace :projects do
    resources :projects, only: [:index, :show, :new, :create, :edit, :update, :destroy] do
      member { post :transition }
    end
    resources :tasks, only: [:index, :create, :update, :destroy] do
      member { post :transition }
    end
  end
  namespace :goals do
    resources :goals, only: [:index, :show, :new, :create, :edit, :update, :destroy] do
      member { post :transition }
    end
    resources :kpis, only: [:index, :show, :new, :create, :edit, :update, :destroy] do
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
  resources :locations
  namespace :finance do
    get "/accounts", to: "accounts#show", as: :accounts
    resources :chart_of_accounts, only: [:index, :new, :create, :edit, :update] do
      member do
        post :archive
        post :restore
      end
    end
    resources :expenses, only: [:index, :new, :create, :edit, :update, :destroy] do
      member { post :restore }
    end
    resources :vendor_payments, only: [:index, :new, :create, :destroy] do
      member { post :restore }
    end
  end
  namespace :purchasing do
    resources :vendors
    resources :purchase_orders, only: [:index, :show, :new, :create, :edit, :update, :destroy] do
      member do
        post :place_order
        post :receive
        post :cancel
        post :add_line
        post :remove_line
      end
    end
  end
  namespace :people do
    resources :employees, only: [:index, :show, :new, :create, :edit, :update, :destroy] do
      member { post :transition }
    end
    resources :departments, only: [:index, :new, :create, :edit, :update]
    resources :positions, only: [:index, :new, :create, :edit, :update]
    resources :timesheets, only: [:index, :show, :new, :create, :edit, :update, :destroy] do
      member do
        post :submit
        post :approve
        post :reject
        post :reopen
        post :add_entry
        post :remove_entry
      end
    end
    resources :leave_requests, only: [:index, :show, :new, :create, :destroy] do
      member do
        post :approve
        post :deny
        post :cancel
      end
    end
    resources :pay_runs, only: [:index, :show, :new, :create] do
      member do
        post :finalize
        post :pay
        post :generate_payslips
        post :add_payslip
        post :remove_payslip
      end
    end
  end
  resources :shopify_variants, only: [:show] do
    member do
      post :link
      post :unlink
    end
  end
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
  resources :reports, only: [:index] do
    collection do
      get :sales
      get :financial
      get :inventory
      get :operations
    end
  end
  resources :ledger, only: :index
  resources :alerts, only: :index do
    collection do
      post :update_status
      post :bulk_update
    end
  end
  resources :syncs, only: [:index, :create] do
    collection do
      post :source
      post :import_swipesimple
    end
  end
  get "/system", to: "system#index", as: :system
  get "/connections", to: "connections#index", as: :connections
  get "/activity", to: "activity#index", as: :activity
  get "/live/sync_status", to: "live#sync_status"

  resource :settings, only: :show do
    post :tenant
    post :fulfillment_workflow
    post :oauth_credentials
    post :oauth_domains
    delete :oauth_domains, to: "settings#oauth_remove_domain"
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

  resources :size_families, only: [:index, :new, :create, :edit, :update, :destroy] do
    collection do
      post :derive_all
      post :approve_all
    end
    member do
      post :derive
      post :set_root
      post :approve_all
      post :add_member
      post :remove_member
      post :approve
    end
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
