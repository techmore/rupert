# frozen_string_literal: true

module People
  # Team → Clock devices: the browsers and tablets a manager has registered so PIN punches from them
  # are trusted (docs/time-and-pay/DECISIONS.md, buddy-punch prevention). Registering sets a signed,
  # long-lived cookie in this browser; only its digest is stored. Revoking stops the cookie working.
  class ClockDevicesController < AuthenticatedController
    before_action { authorize(:module, :hr_write?) }

    def index
      @devices = ClockDevice.order(revoked_at: :asc, last_seen_at: :desc)
      @locations = Location.for_shifts.order(:name)
      @this_device = ClockDevice.authenticate(cookies.signed[ClockDevice::COOKIE])
    end

    def create
      device, secret = ClockDevice.register!(name: params[:name].to_s.strip.presence || 'Store device', location_id: params[:location_id].presence)
      cookies.signed[ClockDevice::COOKIE] = { value: secret, expires: 1.year.from_now, httponly: true, same_site: :lax, secure: request.ssl? }
      ActivityLogger.log('clock_device.registered', subject: device, details: { name: device.name, location_id: device.location_id }.to_json)
      redirect_to people_clock_devices_path, notice: "This browser is now the trusted clock device “#{device.name}”."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to people_clock_devices_path, alert: e.record.errors.full_messages.to_sentence
    end

    def destroy
      device = ClockDevice.find(params[:id])
      device.revoke!
      ActivityLogger.log('clock_device.revoked', subject: device, details: { name: device.name }.to_json)
      redirect_to people_clock_devices_path, notice: "“#{device.name}” no longer accepts PIN punches."
    end
  end
end
