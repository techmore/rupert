# frozen_string_literal: true

class User < ActiveRecord::Base
  has_secure_password

  belongs_to :tenant, optional: true

  serialize :dashboard_config, coder: JSON

  validates :email,
    presence: true,
    uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true

  enum :role,
    {
      super_admin: "super_admin",
      admin: "admin",
      manager: "manager",
      cashier: "cashier",
      reader: "reader",
    },
    default: :admin

  # Permission matrix. "*" grants everything.
  ROLE_PERMISSIONS = {
    "super_admin" => ["*"],
    "admin" => [
      "dashboard.read",
      "sales.read",
      "sales.write",
      "customers.read",
      "customers.write",
      "inventory.read",
      "inventory.write",
      "reconcile.read",
      "reconcile.write",
      "ledger.read",
      "ledger.write",
      "projects.read",
      "projects.write",
      "alerts.read",
      "alerts.write",
      "sync.read",
      "sync.write",
      "settings.read",
    ],
    "manager" => [
      "dashboard.read",
      "sales.read",
      "customers.read",
      "customers.write",
      "inventory.read",
      "inventory.write",
      "reconcile.read",
      "ledger.read",
      "projects.read",
      "projects.write",
      "alerts.read",
      "alerts.write",
      "sync.read",
    ],
    "cashier" => [
      "dashboard.read",
      "sales.read",
      "sales.write",
      "customers.read",
      "inventory.read",
      "alerts.read",
    ],
    "reader" => [
      "dashboard.read",
      "sales.read",
      "customers.read",
      "inventory.read",
      "reconcile.read",
      "ledger.read",
      "alerts.read",
    ],
  }.freeze

  def can?(permission)
    perms = ROLE_PERMISSIONS.fetch(role, [])
    perms.include?("*") || perms.include?(permission.to_s)
  end

  # Dashboard widget configuration as a hash (see DashboardWidget).
  def dashboard_config_hash
    value = dashboard_config
    value.is_a?(Hash) ? value : {}
  end
end
