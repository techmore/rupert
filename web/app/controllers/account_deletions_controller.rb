# frozen_string_literal: true

# A person deletes their own account (account menu → Delete my account). The iPhone app links
# here too: App Store guideline 5.1.1(v) asks for deletion inside the app. See AccountDeletion.
class AccountDeletionsController < AuthenticatedController
  # Only ever acts on the signed-in person's own account.
  skip_after_action :verify_authorized
  before_action { response.headers['Cache-Control'] = 'no-store' }

  def show
    @deletion = AccountDeletion.new(Current.user)
  end

  def destroy
    user = Current.user
    AccountDeletion.new(user).delete!(confirmation: params[:confirmation])
    ActivityLogger.log('account_deleted', subject: user, details: 'The person deleted their own account', actor: user)
    reset_session
    redirect_to login_path, notice: 'Your account is deleted.'
  rescue AccountDeletion::Refused => error
    @deletion = AccountDeletion.new(user)
    flash.now[:alert] = error.message
    render :show, status: :unprocessable_entity
  end
end
