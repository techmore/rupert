# frozen_string_literal: true

module Api
  module V1
    # Employee credentials have no catalog, ERP, or administrator scopes.
    class EmployeeBaseController < ActionController::API
      around_action :isolated_context
      before_action :require_employee_app_enabled
      before_action :authenticate_employee
      around_action :use_business_zone
      rescue_from TimeRules::FeatureDisabled, with: :feature_disabled
      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from Pundit::NotAuthorizedError, with: :forbidden
      rescue_from TimesheetWorkflow::Error, ActiveRecord::RecordInvalid, AASM::InvalidTransition, ActiveRecord::StaleObjectError, with: :invalid
      rescue_from ActionController::ParameterMissing, with: :invalid

      private

      def isolated_context
        Current.reset
        response.headers['Cache-Control'] = 'no-store'
        yield
      ensure
        Current.reset
      end

      # Runs before every action, sign-in included, so a disabled app never
      # issues or accepts a token.
      def require_employee_app_enabled
        return if EmployeeAppSession.enabled?

        render json: { error: 'employee_app_disabled', message: 'The Rupert staff app is turned off for this workspace.' },
          status: :service_unavailable
      end

      def authenticate_employee
        secret = request.headers['Authorization'].to_s.match(/\ABearer (\S+)\z/i)&.captures&.first
        @employee_session = EmployeeAppSession.authenticate(secret)
        unless @employee_session
          response.headers['WWW-Authenticate'] = 'Bearer realm="Rupert Staff"'
          return render json: { error: 'unauthorized' }, status: :unauthorized
        end
        Current.user = @employee_session.user
        Current.tenant = @employee_session.tenant
      end

      # The workspace's clock for day, week and pay-period boundaries (set after the token names the workspace).
      def use_business_zone(&)
        name = Current.tenant&.time_zone.presence
        return yield unless name

        Time.use_zone(BusinessClock.display_zone(name), &)
      end

      def require_time_feature(*names)
        names.each { |name| TimeRules.require_feature!(name) }
      end

      # A time feature an administrator turned off (Settings → Time rules).
      def feature_disabled(error)
        render json: { error: 'feature_disabled', feature: error.feature, message: error.message }, status: :forbidden
      end

      def not_found
        render json: { error: 'not_found' }, status: :not_found
      end

      def forbidden
        render json: { error: 'forbidden' }, status: :forbidden
      end

      def invalid(error)
        message = error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.to_sentence : error.message
        render json: { error: 'invalid_request', message: message }, status: :unprocessable_entity
      end

      def worker
        @employee_session.employee
      end
    end
  end
end
