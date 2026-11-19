# frozen_string_literal: true

# Rupert-owned stock (Rupert as the primary inventory). See
# docs/plans/rupert-master-inventory.md. Nothing in this namespace writes to a
# platform; MasterStock::PushPreview only describes the writes it would make.
module MasterStock
  class Error < StandardError; end

  LABELS = { 'shopify' => 'Shopify', 'ctrax' => 'C-Trax', 'square' => 'Square', 'rupert' => 'Rupert' }.freeze
  MAX_UNITS = 1_000_000

  def self.platform_label(platform) = LABELS.fetch(platform.to_s, platform.to_s.humanize)

  def self.require_actor!(actor, *permissions)
    unless Current.tenant_id.present? && actor&.active? && (actor.tenant_id == Current.tenant_id || actor.super_admin?) &&
        (['inventory.read', 'inventory.write', *permissions]).all? { |permission| actor.can?(permission) }
      raise Error, 'Inventory read and write permissions are required.'
    end
  end

  # One allocation lock per workspace, shared with transfers and reservations.
  def self.serialized(&)
    StockLedgerEntry.transaction do
      Tenant.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
      yield
    end
  end
end
