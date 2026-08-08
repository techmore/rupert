# frozen_string_literal: true

class HomeController < ApplicationController
  def index
    return redirect_to(onboarding_path) unless OnboardingController.configured?

    @widgets = DashboardWidget.entries(Current.user.dashboard_config_hash)
    render("home/index")
  end

  # POST /dashboard/customize — save the user's widget layout to their profile.
  # Body: { widgets: [keys in display order], hidden: [keys] } or { reset: true }.
  def customize
    if params[:reset]
      Current.user.update!(dashboard_config: nil)
      return render(json: { ok: true, reset: true })
    end

    widgets = Array(params[:widgets])
    hidden = Array(params[:hidden])

    if widgets.any? { |key| DashboardWidget.find(key).nil? }
      return render(json: { ok: false, error: "Unknown widget in layout" }, status: :unprocessable_entity)
    end

    Current.user.update!(dashboard_config: { "widgets" => widgets, "hidden" => hidden })
    render(json: { ok: true, widgets: widgets, hidden: hidden })
  rescue ActiveRecord::RecordInvalid => e
    render(json: { ok: false, error: e.message }, status: :unprocessable_entity)
  end
end
