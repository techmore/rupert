# frozen_string_literal: true

# Employee directory + role assignment. Super-admin only: employees can manage
# their team but never their own role or access.
class UsersController < AuthenticatedController
  before_action :authorize_users
  before_action :set_user, only: [:edit, :update, :destroy, :deactivate, :activate, :update_permissions]

  def index
    @users = User.where(tenant_id: Current.tenant_id).ordered
    @roles = User.roles.keys
  end

  def new
    @user = User.new(tenant_id: Current.tenant_id, role: "cashier")
    @roles = User.roles.keys
  end

  def create
    @user = User.new(user_params.merge(tenant_id: Current.tenant_id))
    if @user.save
      redirect_to(users_path, notice: "#{@user.display_name} added.")
    else
      @roles = User.roles.keys
      render(:new, status: :unprocessable_entity)
    end
  end

  def edit
    @roles = User.roles.keys
    @catalog = User.permission_catalog
  end

  # Replace an employee's per-person permission overrides. Empty selection
  # clears them, falling back to the role's permissions.
  def update_permissions
    raw = params[:permissions]
    permissions = raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h.keys : []
    @user.update_permission_overrides!(permissions)
    redirect_to(edit_user_path(@user), notice: "Permissions updated for #{@user.display_name}.")
  end

  def update
    if @user.update(user_params)
      redirect_to(users_path, notice: "#{@user.display_name} updated.")
    else
      @roles = User.roles.keys
      render(:edit, status: :unprocessable_entity)
    end
  end

  def destroy
    return redirect_to(users_path, alert: "You can't remove your own account.") if @user == Current.user

    @user.destroy
    redirect_to(users_path, notice: "#{@user.display_name} removed.")
  end

  def deactivate
    return redirect_to(users_path, alert: "You can't deactivate your own account.") if @user == Current.user

    @user.update!(active: false)
    redirect_to(users_path, notice: "#{@user.display_name} deactivated.")
  end

  def activate
    @user.update!(active: true)
    redirect_to(users_path, notice: "#{@user.display_name} reactivated.")
  end

  private

  def authorize_users
    authorize(:module, :users_write?)
  end

  def set_user
    @user = User.find_by!(tenant_id: Current.tenant_id, id: params[:id])
  end

  def user_params
    params.require(:user).permit(:name, :email, :role, :password, :active)
  end
end
