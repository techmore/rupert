# frozen_string_literal: true

# Employee directory + role assignment. Super-admin only: employees can manage
# their team but never their own role or access.
class UsersController < AuthenticatedController
  before_action :authorize_read, only: [:index, :edit]
  before_action :authorize_write, except: [:index, :edit]
  before_action :set_user, only: [:edit, :update, :destroy, :deactivate, :activate, :update_permissions]
  before_action :guard_super_admin, only: [:update, :destroy, :deactivate, :update_permissions]

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
      ActivityLogger.log("employee_added", subject: @user, details: @user.role)
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
    ActivityLogger.log("employee_permissions", subject: @user, details: permissions.join(", "))
    redirect_to(edit_user_path(@user), notice: "Permissions updated for #{@user.display_name}.")
  end

  def update
    if @user.update(user_params)
      ActivityLogger.log("employee_updated", subject: @user, details: @user.role)
      redirect_to(users_path, notice: "#{@user.display_name} updated.")
    else
      @roles = User.roles.keys
      render(:edit, status: :unprocessable_entity)
    end
  end

  def destroy
    return redirect_to(users_path, alert: "You can't remove your own account.") if @user == Current.user

    @user.destroy
    ActivityLogger.log("employee_removed", subject: @user)
    redirect_to(users_path, notice: "#{@user.display_name} removed.")
  end

  def deactivate
    return redirect_to(users_path, alert: "You can't deactivate your own account.") if @user == Current.user

    @user.update!(active: false)
    ActivityLogger.log("employee_deactivated", subject: @user)
    redirect_to(users_path, notice: "#{@user.display_name} deactivated.")
  end

  def activate
    @user.update!(active: true)
    ActivityLogger.log("employee_reactivated", subject: @user)
    redirect_to(users_path, notice: "#{@user.display_name} reactivated.")
  end

  private

  def authorize_read
    authorize(:module, :users_read?)
  end

  def authorize_write
    authorize(:module, :users_write?)
  end

  def set_user
    @user = User.find_by!(tenant_id: Current.tenant_id, id: params[:id])
  end

  # Non-super-admins can't modify or deactivate a super admin account.
  def guard_super_admin
    return if Current.user.super_admin?

    redirect_to(users_path, alert: "Only the super admin can modify a super admin account.") if @user.super_admin?
  end

  def user_params
    permitted = [:name, :email, :password, :active]
    permitted << :role if Current.user.super_admin?
    params.require(:user).permit(*permitted)
  end
end
