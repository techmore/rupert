# frozen_string_literal: true

module Marketing
  # Marketing events and campaign tasks (#415): the shared work-item rules (Work::ItemPolicy: marketing.read to see,
  # marketing.write to change), and only while the workspace has Marketing turned on. Staff accounts never see them.
  class WorkItemPolicy < Work::ItemPolicy
    %i[show? create? update? destroy?].each do |name|
      define_method(name) { FeatureFlag.enabled?(:marketing) && !user&.employee? && super() }
    end

    def index? = show?
    def transition? = update?

    class Scope < Work::ItemPolicy::Scope
      def resolve
        return @scope.none unless FeatureFlag.enabled?(:marketing) && !@user&.employee?

        super
      end
    end
  end
end
