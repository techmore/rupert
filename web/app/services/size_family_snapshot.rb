# frozen_string_literal: true

# Renders a size family for display: base grams, each member's current Square
# quantity, derived target, pending change, and in-sync state, plus the
# optional root item. Consolidates the near-identical math that was duplicated
# across the Sizes page, the Reconcile page, and the inventory PDF.
class SizeFamilySnapshot
  Member = Struct.new(:member, :current, :target, :pending, :in_sync, keyword_init: true)

  attr_reader :family

  def self.all
    SizeFamily.order(:name).includes(:members).map { |family| new(family) }
  end

  def initialize(family)
    @family = family
  end

  def root_grams
    @root_grams ||= family.base_grams&.to_f
  end

  def members
    @members ||= begin
      pending_by_sku = family.size_changes.pending.index_by { |change| change.sku.downcase }
      family.members.order(:grams).map do |member|
        current = member.square_variation_id ? InventoryLevel.total_for_variation(member.square_variation_id) : nil
        target = root_grams ? (root_grams / member.grams.to_f).floor : nil
        pending = pending_by_sku[member.sku.downcase]
        Member.new(
          member: member,
          current: current,
          target: target,
          pending: pending,
          in_sync: pending.nil? && !target.nil? && target == current
        )
      end
    end
  end

  def pending_count
    @pending_count ||= family.size_changes.pending.count
  end

  def last_derived
    @last_derived ||= family.size_changes.maximum(:updated_at)
  end

  # The root item (physical root gram product) if the family defines a root SKU.
  def root_item
    return nil if family.root_sku.blank?

    variation = SquareVariation.find_by(sku: family.root_sku)
    {
      sku: family.root_sku,
      current: variation ? InventoryLevel.total_for_variation(variation.id) : nil
    }
  end
end
