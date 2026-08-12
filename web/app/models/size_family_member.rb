# frozen_string_literal: true

# One size offered within a SizeFamily, e.g. sku "afghan5" = 5 grams.
class SizeFamilyMember < ApplicationRecord
  include TenantScoped

  belongs_to :family,
    class_name: "SizeFamily",
    foreign_key: "family_id",
    inverse_of: :members

  validates :sku, presence: true, uniqueness: { scope: :family_id, case_sensitive: false }
  validates :grams, numericality: { greater_than: 0 }

  before_save { self.sku = sku.to_s.strip }
end
