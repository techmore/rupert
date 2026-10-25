# frozen_string_literal: true

module Training
  # Training assignments (#409) on the shared work-item table: hr.read sees every assignment in the workspace, hr.write
  # assigns and cancels, and everyone else (staff accounts included) sees and works only the training assigned to
  # them. Assignments are never destroyed.
  class AssignmentPolicy < Work::ItemPolicy
    def show?
      return false unless active_in_workspace?

      own? || (!user.employee? && (can?(:read) || can?(:write)))
    end

    def index? = show?
    def create? = active_in_workspace? && !user.employee? && can?(:write)
    def update? = create?
    def transition? = active_in_workspace? && (own? || create?)
    def destroy? = false

    class Scope < Work::ItemPolicy::Scope
      def resolve
        return @scope.none unless @user&.active? && (@user.super_admin? || @user.tenant_id.present?)

        items = (@user.super_admin? ? @scope : @scope.where(tenant_id: @user.tenant_id)).where(kind: @kind.key)
        return items if !@user.employee? && (@user.can?(@kind.permissions[:read]) || @user.can?(@kind.permissions[:write]))

        items.where(assignee_id: @user.id.to_s)
      end
    end

    private

    def own? = record.assignee_id.present? && record.assignee_id.to_s == user.id.to_s
  end
end
