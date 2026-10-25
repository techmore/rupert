# frozen_string_literal: true

module Finance
  # A money-out record: any business expense (supplies, shipping, labor, rent,
  # etc.). Optionally tied to a vendor.
  class Expense < ApplicationRecord
    include Discard::Model
    include TenantScoped
    include FinanceAmount
    include LockedPeriodGuard

    self.table_name = 'expenses'

    # Exclude discarded rows by default (undiscarded); the ledger/AP queries
    # don't chain .kept, so this keeps deleted records out of the books.
    default_scope { undiscarded }

    CATEGORIES = %w[
      cost_of_goods
      shipping
      labor
      rent
      utilities
      marketing
      advertising
      store
      software
      supplies
      insurance
      taxes
      other
    ].freeze
    METHODS = %w[card cash check bank_transfer other].freeze

    belongs_to :vendor, class_name: 'Purchasing::Vendor', optional: true
    belongs_to :account, class_name: 'Finance::Account', optional: true
    guard_locked_period :incurred_on

    validate :category_known
    validate :vendor_and_account_belong_to_workspace
    validates :amount_cents, numericality: { greater_than: 0, less_than_or_equal_to: 2_147_483_647 }
    validates :incurred_on, presence: true

    scope :by_category, ->(category) { category.present? && category != 'all' ? where(category: category) : all }
    scope :since, ->(date) { where('incurred_on >= ?', date) }
    scope :recent, ->(limit = 200) { order(incurred_on: :desc, created_at: :desc).limit(limit) }

    def category_label
      Finance::ExpenseCategory.label_for(category)
    end

    private

    # A vendor or ledger account id from another workspace would read back as nil through the
    # tenant-scoped association, so check the ids themselves (as Projects::Task does for projects).
    def vendor_and_account_belong_to_workspace
      workspace = tenant_id || Current.tenant_id
      if vendor_id.present? && !Purchasing::Vendor.tenant_unscoped(workspace).exists?(id: vendor_id)
        errors.add(:vendor, 'must belong to this workspace')
      end
      return if account_id.blank? || Finance::Account.tenant_unscoped(workspace).exists?(id: account_id)

      errors.add(:account, 'must belong to this workspace')
    end

    # Any category this workspace has; a new or changed category must be active.
    def category_known
      known = Finance::ExpenseCategory.known_keys
      allowed = new_record? || category_changed? ? Finance::ExpenseCategory.active_keys : known
      errors.add(:category, 'is not an active expense category') unless allowed.include?(category)
    end
  end
end
