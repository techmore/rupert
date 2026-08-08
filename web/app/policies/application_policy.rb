# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index?
    false
  end

  def show?
    false
  end

  def create?
    false
  end

  def new?
    create?
  end

  def update?
    false
  end

  def edit?
    update?
  end

  def destroy?
    false
  end

  # Convenience: gate whole modules by permission key (see User::ROLE_PERMISSIONS).
  def module?(key)
    user&.can?(key)
  end

  private

  def tenant?
    record.respond_to?(:tenant_id) ? record.tenant_id == user&.tenant_id : true
  end
end
