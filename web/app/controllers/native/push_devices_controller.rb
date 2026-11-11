# frozen_string_literal: true

module Native
  # The iPhone app registers its APNs device token for the signed-in person
  # (POST /native/push_devices {platform, token, environment, app_version}) and forgets it on sign-out
  # (DELETE /native/push_devices/:token_digest). The request comes from the app's own HTTP client
  # with the session cookie, never from a page, so there is no CSRF token to check.
  class PushDevicesController < ApplicationController
    skip_forgery_protection
    # Forgetting a device needs no session: the app calls it after the sign-out it follows, and the
    # digest of the phone's own push token (256 bits only that phone and this server know) is the proof.
    skip_before_action :require_login, only: :destroy
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
      PushDevice.forget_token!(params[:token_digest])
      head :no_content
    end
  end
end
