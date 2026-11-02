# frozen_string_literal: true

module Compliance
  # A manager sets their own register override PIN, confirming their password.
  class OverridePinsController < AuthenticatedController
    before_action do
      raise Pundit::NotAuthorizedError unless Current.user.can_approve_pos_override?

      skip_authorization # gate: can_approve_pos_override? (managers and owners); a user only sets their own PIN
    end

    def edit; end

    def update
      user = Current.user
      return redirect_to(edit_compliance_override_pin_path, alert: 'Your password is not right.') unless user.authenticate(params[:current_password].to_s)
      return redirect_to(edit_compliance_override_pin_path, alert: 'The two PINs do not match.') unless params[:pin].to_s == params[:pin_confirmation].to_s

      User.transaction do
        user.pos_override_pin = params[:pin].to_s
        user.save!(validate: false)
        ComplianceEvent.record!('override_pin_set', subject: user)
      end
      redirect_to compliance_path, notice: 'Override PIN saved. Use it with a reason to approve a blocked sale.'
    rescue ArgumentError => error
      redirect_to edit_compliance_override_pin_path, alert: error.message
    end
  end
end
