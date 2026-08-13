# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Application-wide content security policy. The app is a Shopify embedded app,
# so frame-ancestors is locked to the Shopify admin origins; script/style are
# relaxed with 'unsafe-inline' because the views use inline JS/ERB (tightening
# to nonce-based script-src is tracked as follow-up work).
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self, :https
    policy.font_src    :self, :https, :data
    policy.img_src     :self, :https, :data
    policy.object_src  :none
    policy.base_uri    :self
    policy.form_action :self, :https
    policy.script_src  :self, :https, :unsafe_inline
    policy.style_src   :self, :https, :unsafe_inline
    policy.connect_src :self, :https
    policy.frame_ancestors :self, "https://admin.shopify.com", "https://*.myshopify.com"
  end
end
