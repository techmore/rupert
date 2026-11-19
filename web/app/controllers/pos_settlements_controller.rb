# frozen_string_literal: true

# Read-only settlement reconciliation for a store's card gateway (F69).
class PosSettlementsController < AuthenticatedController
  before_action do
    raise Pundit::NotAuthorizedError unless Current.user.can?('settings.write') && Current.user.can?('sales.write')

    skip_authorization # gate: settings.write + sales.write, as checkout setup
    response.headers['Cache-Control'] = 'no-store'
  end

  def show
    @location = Location.find_by!(id: params[:location_id], source: 'ctrax')
    @setting = PosSetting.find_by(location: @location)
    @to_date = parse_date(params[:to]) || Date.current
    @from_date = parse_date(params[:from]) || (@to_date - 6)
    return unless @setting&.verified_at && params[:run] == '1'

    zone = Time.zone
    @report = Pos::SettlementReconciliation.call(setting: @setting, from: zone.local(@from_date.year, @from_date.month, @from_date.day),
      to: zone.local(@to_date.year, @to_date.month, @to_date.day) + 1.day)
  rescue Pos::Error => e
    flash.now[:alert] = e.message
  end

  private

  def parse_date(value)
    value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(value) : nil
  rescue Date::Error
    nil
  end
end
