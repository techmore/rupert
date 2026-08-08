# frozen_string_literal: true

# Platform admin (super admin) manages tenants.
class TenantsController < ApplicationController
  before_action :require_super_admin

  def index
    @tenants = Tenant.order(:name)
  end

  def new
    @tenant = Tenant.new
  end

  def create
    @tenant = Tenant.new(
      name: params[:name],
      subdomain: params[:subdomain],
      shopify_shop_domain: params[:shopify_shop_domain]
    )
    if @tenant.save
      redirect_to tenants_path, notice: "Tenant #{@tenant.name} created at #{@tenant.subdomain}.#{request.domain}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def require_super_admin
    redirect_to root_path, alert: "Not authorized" unless Current.user&.super_admin?
  end
end
