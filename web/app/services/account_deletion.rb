# frozen_string_literal: true

# Deletes a person's own Rupert account (Settings → Delete my account, also in the iPhone app,
# which App Store guideline 5.1.1(v) requires).
#
# The sign-in and the personal details go: name, email, password, Google links, API tokens and
# app sessions. The account row stays as an anonymous, inactive "Deleted user" because the
# business's own records (sales, counts, chat, audit history) point at it and the business must
# keep them; they then show "Deleted user" instead of the person.
class AccountDeletion
  class Refused < StandardError; end

  CONFIRMATION = 'DELETE'

  def initialize(user)
    @user = user
  end

  # Why this account cannot delete itself right now, or nil.
  def blocker
    return 'This account is already deleted.' unless @user.active?
    return nil unless @user.super_admin?

    others = User.where(role: 'super_admin', active: true).where.not(id: @user.id)
    'You are the only platform administrator. Make someone else a platform administrator first.' unless others.exists?
  end

  def delete!(confirmation:)
    raise Refused, blocker if blocker
    raise Refused, "Type #{CONFIRMATION} to confirm." unless confirmation.to_s.strip.upcase == CONFIRMATION

    now = Time.current
    User.transaction do
      @user.google_login_identities.destroy_all
      ApiAccessToken.where(user_id: @user.id, revoked_at: nil).update_all(revoked_at: now)
      EmployeeAppSession.where(user_id: @user.id, revoked_at: nil).update_all(revoked_at: now)
      @user.user_permissions.destroy_all
      @user.update!(
        name: 'Deleted user',
        email: "deleted-#{@user.id}-#{SecureRandom.hex(4)}@deleted.invalid",
        password: SecureRandom.base58(32),
        active: false,
        dashboard_config: nil
      )
    end
    true
  end
end
