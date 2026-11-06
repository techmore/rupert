# frozen_string_literal: true

module Native
  # The iPhone app registers its APNs device token for the signed-in person
  # (POST /native/push_devices {platform, token, environment, app_version}) and forgets it on sign-out
  # (DELETE /native/push_devices/:token_digest). The request comes from the app's own HTTP client
  # with the session cookie, never from a page, so there is no CSRF token to check.
  class PushDevicesController < ApplicationController
    skip_forgery_protection
    before_action { response.headers['Cache-Control'] = 'no-store' }

    def create
      platform = params[:platform].to_s
      token = params[:token].to_s.strip
      if !PushDevice::PLATFORMS.include?(platform) || token.blank? || token.length > 4000
        return render(json: { error: 'platform and token are required' }, status: :unprocessable_entity)
      end

      device = PushDevice.register!(user: Current.user, platform: platform, token: token, environment: params[:environment], app_version: params[:app_version])
      render json: { id: device.id, token_digest: device.token_digest, push_configured: PushNotifier.configured? }, status: :created
    end

    def destroy
      device = PushDevice.find_by(user_id: Current.user.id, token_digest: params[:token_digest].to_s)
      device&.disable!('signed out')
      head :no_content
    end
  end
end
