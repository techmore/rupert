# frozen_string_literal: true

class User < ActiveRecord::Base
  has_secure_password

  belongs_to :tenant, optional: true

  serialize :dashboard_config, coder: JSON

  validates :email, presence: true, uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true

  enum :role, { admin: "admin", super_admin: "super_admin" }, default: :admin

  # Dashboard widget configuration as a hash (see DashboardWidget).
  def dashboard_config_hash
    value = dashboard_config
    value.is_a?(Hash) ? value : {}
  end
end
