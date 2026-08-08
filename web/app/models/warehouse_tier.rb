# frozen_string_literal: true

# A bulk-quantity discount threshold. A nil shareId marks a global default
# tier; otherwise the tier belongs to one WarehouseShare's custom schedule.
class WarehouseTier < ApplicationRecord
  include HasCuid

  self.table_name = "WarehouseTier"
  self.primary_key = "id"

  belongs_to :share, class_name: "WarehouseShare", foreign_key: "shareId", optional: true

  validates :minQty, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :discountPercent,
    presence: true,
    numericality: { greater_than_or_equal_to: 0, less_than: 100 }

  def label
    "#{minQty}+ units · #{discountPercent.to_i}% off"
  end
end
