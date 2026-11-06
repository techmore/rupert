# frozen_string_literal: true

# Who an assignment rule can reach. Roles come from the account; locations have no account
# link yet (docs/lms/OPEN-QUESTIONS.md), so the list is empty until one exists.
module Lms::Audience
  module_function

  def location_ids_for(_user)
    []
  end

  # Accounts in the current workspace that a rule reaches.
  def users_for(rule)
    User.where(tenant_id: rule.tenant_id).active.select { |user| rule.matches?(user) }
  end

  # Roles offered when a manager writes a rule: everyone, then each role.
  def role_options
    [['Everyone', '']] + User.roles.keys.map { |role| [role.humanize, role] }
  end
end
