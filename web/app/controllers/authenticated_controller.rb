# frozen_string_literal: true

# Base controller for signed-in, tenant-scoped pages. Includes Pundit so every
# action can authorize against a policy, and the shared nav is built from the
# module registry.
class AuthenticatedController < ApplicationController
  include Pundit::Authorization
  include Pagy::Method

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized
  before_action :note_presence
  # Safety net: every action must either authorize against a policy (including
  # headless `authorize(:module, ...)`) or pass a controller gate that calls
  # `skip_authorization`. Controllers whose records are scoped to the signed-in
  # user opt out with `skip_after_action :verify_authorized` and a reason.
  # An action that does neither raises Pundit::AuthorizationNotPerformedError in
  # development and test. In production the miss is reported instead, so a gap
  # the suite didn't reach shows up in error reports rather than as a broken page.
  after_action :verify_authorized

  # Pagy 43 removed the legacy :last_page overflow option. Preserve the app's
  # existing behavior by retrying an out-of-range request at that paginator's
  # last page, without redirecting or discarding active filters.
  def pagy(paginator, collection, **options)
    super
  rescue Pagy::RangeError => error
    super(paginator, collection, **options.merge(page: error.pagy.last))
  end

  private

  def verify_authorized
    super
  rescue Pundit::AuthorizationNotPerformedError => error
    raise unless Rails.env.production?

    Rails.error.report(error, handled: true, severity: :warning,
      context: { controller: controller_path, action: action_name, tenant_id: Current.tenant_id })
  end

  # Records that someone took data out of Rupert (CSV, original, backup).
  # Never raises; the details name the export, not its contents.
  def log_export(label, details = nil)
    ActivityLogger.log('data_exported', details: [label, details].compact.join(': '))
  end

  # "Recently active" in team chat: a page view counts (at most one write a minute).
  def note_presence
    return unless request.get? && request.format.html?
    # Previews (an administrator viewing employee screens) write nothing.
    return if controller_name == 'employee_preview' || params[:preview].to_s == '1'

    TeamChat::Presence.touch(Current.user)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[presence] #{e.class}")
  end

  def pundit_user
    Current.user
  end

  def user_not_authorized(error = nil)
    @ops_denied = { via: 'pundit', policy: error.try(:policy)&.class&.name, query: error.try(:query)&.to_s }.compact
    flash[:alert] = "You don't have permission to do that."
    redirect_back(fallback_location: root_path)
  end
end
