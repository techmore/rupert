# frozen_string_literal: true

module Work
  # Default permissions for a work-item kind that has no policy of its own, read from the kind's registry entry:
  #   read         — may see every item of the kind in the workspace
  #   write        — may create, change, reassign, transition and delete them
  #   self_service — staff (employee) accounts with this permission see and work only items assigned to them
  # Kinds with their own policy (task → Projects::TaskPolicy) use that instead; `Work::ItemPolicy.for` picks.
  class ItemPolicy < ApplicationPolicy
    def self.for(user, item) = item.kind_definition.policy_class.new(user, item.specific)

    def index? = show?

    def show?
      return false unless active_in_workspace?
      return self_service? if user.employee?

      can?(:read) || can?(:write)
    end

    def create?
      active_in_workspace? && !user.employee? && can?(:write)
    end

    def update?
      return false unless active_in_workspace?
      return self_service? if user.employee?

      can?(:write)
    end

    def transition? = update?
    def destroy? = create?

    class Scope
      def initialize(user, scope, kind:)
        @user = user
        @scope = scope
        @kind = Work::Registry.fetch(kind)
      end

      def resolve
        return @scope.none unless @user&.active? && (@user.super_admin? || @user.tenant_id.present?)

        items = (@user.super_admin? ? @scope : @scope.where(tenant_id: @user.tenant_id)).where(kind: @kind.key)
        permission = ->(key) { @kind.permissions[key].present? && @user.can?(@kind.permissions[key]) }
        if @user.employee?
          permission.call(:self_service) ? items.where(assignee_id: @user.id.to_s) : items.none
        elsif permission.call(:read) || permission.call(:write)
          items
        else
          items.none
        end
      end
    end

    private

    def kind = record.kind_definition

    def can?(key)
      permission = kind.permissions[key]
      permission.present? && module?(permission)
    end

    def active_in_workspace?
      user&.active? && tenant? && (user.super_admin? || user.tenant_id.present?)
    end

    def self_service?
      can?(:self_service) && record.assignee_id.present? && record.assignee_id.to_s == user.id.to_s
    end
  end
end
