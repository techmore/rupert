# frozen_string_literal: true

# A base-gram product offered in multiple "theoretical" sizes. The family
# tracks a root gram bank (base_grams, source of truth) and derives each
# member size's quantity as floor(root_grams / member.grams). Sales of any
# member size are folded into root_grams on each derivation run.
class SizeFamily < ApplicationRecord
  include TenantScoped

  MODES = ["approval", "auto"].freeze

  has_many :members,
    class_name: "SizeFamilyMember",
    foreign_key: "family_id",
    dependent: :destroy,
    inverse_of: :family
  has_many :size_changes,
    class_name: "SizeChange",
    foreign_key: "family_id",
    dependent: :destroy,
    inverse_of: :family

  validates :name, presence: true
  validates :mode, inclusion: { in: MODES }
  validates :root_sku, format: { with: /\A[A-Za-z0-9.\-_]+\z/, allow_blank: true }

  def approval?
    mode == "approval"
  end

  def auto?
    mode == "auto"
  end

  def member_by_sku(sku)
    members.find { |member| member.sku.casecmp?(sku.to_s) }
  end
end
