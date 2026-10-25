# frozen_string_literal: true

module Marketing
  # What a marketing event observably produced (#415): how many times a code was redeemed and the revenue of those
  # orders, per event, code, order source, store location and currency (money in different currencies is never
  # added together). A row is either counted from Rupert's stored orders (basis 'stored_orders', read-only: see
  # Marketing::RedemptionCount) or entered by a person (basis 'manual', e.g. a paper tally at a market stall). One
  # event never mixes the two for the same code, and an order counted for one event is not counted for another, so
  # results cannot be double-counted.
  class Result < Record
    self.table_name = 'marketing_results'

    BASES = { 'stored_orders' => 'Stored orders', 'manual' => 'Entered by hand' }.freeze

    belongs_to :event, class_name: 'Work::Item', foreign_key: :work_item_id, inverse_of: false
    belongs_to :offer, class_name: 'Marketing::Offer', optional: true
    belongs_to :recorded_by, class_name: 'User', optional: true

    attribute :order_ids, :json, default: -> { [] }

    before_validation do
      self.code = code.to_s.strip.upcase
      self.currency = currency.to_s.strip.upcase.presence || 'USD'
      self.location_id = location_id.to_s.strip
      self.order_source = order_source.to_s.strip
    end

    validates :basis, inclusion: { in: BASES.keys }
    validates :code, format: { with: /\A[A-Z0-9_-]{0,80}\z/, message: 'may use letters, digits, - and _' }
    validates :currency, format: { with: /\A[A-Z]{3}\z/, message: 'must be a three-letter code' }
    validates :redemptions, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 10_000_000 }
    validates :revenue_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 100_000_000_000 }
    validates :summary, length: { maximum: 2000 }
    validates :work_item_id, uniqueness: { scope: %i[tenant_id code order_source location_id currency],
                                           message: 'already has a result for this code, source, location and currency' }
    validate :event_in_workspace
    validate :one_basis_per_code
    validate { errors.add(:window_ends_at, 'must be after the start') if window_starts_at && window_ends_at && window_ends_at <= window_starts_at }
    validate { same_tenant(:offer) if offer_id.present? }

    def order_ids = super || []
    def stored_orders? = basis == 'stored_orders'
    def basis_label = BASES.fetch(basis, basis.to_s.humanize)

    # Order ids already counted by stored-order results of other events in this workspace.
    def self.claimed_order_ids(except_event_id:)
      where(basis: 'stored_orders').where.not(work_item_id: except_event_id).pluck(:order_ids).flat_map { |ids| Array(ids) }.to_set
    end

    private

    def event_in_workspace
      found = Work::Item.tenant_unscoped(tenant_id).exists?(id: work_item_id, kind: 'marketing_event')
      errors.add(:event, 'must be a marketing event in this workspace') unless found
    end

    def one_basis_per_code
      other = self.class.tenant_unscoped(tenant_id).where(work_item_id: work_item_id, code: code).where.not(basis: basis)
      other = other.where.not(id: id) if persisted?
      return unless other.exists?

      errors.add(:base, stored_orders? ? 'This code already has results entered by hand; remove them before counting stored orders.' :
                                         'This code is counted from stored orders; recount instead of entering it by hand.')
    end
  end
end
