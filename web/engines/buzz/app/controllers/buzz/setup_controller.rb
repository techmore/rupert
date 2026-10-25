# frozen_string_literal: true

module Buzz
  # The Buzz module's Setup page: the relay address and default channel, the
  # workspace's Rupert identity (create its key, publish its profile) and an
  # on-demand check against the relay. Administrators with settings.write only.
  # The private key is created here and stored encrypted; it is never shown.
  class SetupController < ::AuthenticatedController
    before_action :require_settings_write

    # GET /buzz/setup
    def show
      @relay_url = Identity.relay_url
      @channel = Identity.channel_id
      @npub = Identity.npub
      @check = Identity.last_check
    end

    # PATCH /buzz/setup { relay_url:, channel: }
    def update
      Settings.update!(relay_url: params[:relay_url], channel: params[:channel])
      ActivityLogger.log('buzz_settings_saved', details: 'relay and channel')
      redirect_to buzz_setup_path, notice: 'Buzz settings saved.'
    rescue Settings::Invalid => e
      redirect_to buzz_setup_path, alert: e.message
    end

    # POST /buzz/setup/keypair — creates (or replaces) the Rupert identity's key.
    def keypair
      npub = Identity.generate_keypair!
      ActivityLogger.log('buzz_identity_created', details: npub.to_s.first(16))
      redirect_to buzz_setup_path, notice: "Rupert's Buzz identity is ready: #{npub}. Publish its profile, then add it to your channels in Buzz."
    end

    # POST /buzz/setup/profile — publishes the identity's kind 0 profile.
    def profile
      ok, message = Identity.publish_profile!
      if ok
        redirect_to buzz_setup_path, notice: 'Profile published. Add the identity to your channels in Buzz.'
      else
        redirect_to buzz_setup_path, alert: "The profile was not published: #{message}."
      end
    end

    # POST /buzz/setup/check — asks the relay whether it answers and knows the identity.
    def check
      status = Identity.check!
      if !status[:configured]
        redirect_to buzz_setup_path, alert: 'Set the relay and create the identity first.'
      elsif !status[:reachable]
        redirect_to buzz_setup_path, alert: "Rupert could not use the relay: #{status[:error]}."
      elsif status[:registered]
        redirect_to buzz_setup_path, notice: 'The relay answers and knows Rupert’s profile.'
      else
        redirect_to buzz_setup_path, notice: 'The relay answers, but has no profile for Rupert yet. Publish the profile.'
      end
    end

    private

    def require_settings_write
      user = Current.user
      return head :forbidden if user.employee? || Current.tenant_id != user.tenant_id

      authorize(:module, :settings_write?)
    end
  end
end
