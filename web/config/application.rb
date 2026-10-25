# frozen_string_literal: true

require_relative 'boot'

require 'rails/all'
require_relative 'shopify_api_version'

# Load the repo-root .env (credentials for the sync engine live there). Skipped
# in the test environment so real credentials on the dev box never leak into
# tests/CI logs — tests provide their own values.
require 'dotenv'
Dotenv.load(File.expand_path('../../.env', __dir__)) unless Rails.env.test?
if ENV['HOST'].present? && !ENV['HOST'].match?(%r{\Ahttps?://})
  ENV['HOST'] = "https://#{ENV['HOST']}"
end

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Optional Buzz module (web/engines/buzz, see its README). Off unless
# RUPERT_BUZZ_ENABLED=1, in every environment; while off it is not loaded at all
# (no routes, pages, navigation, permissions, jobs or relay connections). An
# engine has to be required before the app initializes, so the switch is read here.
require_relative '../engines/buzz/lib/buzz' if ENV.fetch('RUPERT_BUZZ_ENABLED', '0') == '1'

module ShopifyAppTemplateRuby
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults(8.1)

    config.assets.prefix = '/api/assets'

    # ERP modules live in app/modules/<name>. The directory is the autoload
    # root, so app/modules/core/order.rb -> Core::Order. New modules are
    # picked up automatically.
    config.autoload_paths << Rails.root.join('app/modules')

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # lib/ops_log is required explicitly at boot (config/initializers/ops_log.rb): the log
    # formatter and middleware must not be reloaded.
    config.autoload_lib(ignore: %w[assets tasks ops_log ops_log.rb])

    if ShopifyAPI::Context.embedded?
      config.action_dispatch.default_headers = config.action_dispatch.default_headers.merge({
                                                                                              'Access-Control-Allow-Origin' => '*',
                                                                                              'Access-Control-Allow-Headers' => 'Authorization',
                                                                                              'Access-Control-Expose-Headers' => 'X-Shopify-API-Request-Failure-Reauthorize-Url'
                                                                                            })
    end

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # Store timestamps in UTC and display them in the store's local time.
    config.time_zone = 'Eastern Time (US & Canada)'

    # True only when the optional Buzz module was loaded above.
    config.x.buzz_enabled = defined?(Buzz::Engine) ? true : false
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
