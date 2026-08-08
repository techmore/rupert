# frozen_string_literal: true

class User < ActiveRecord::Base
  has_secure_password

  belongs_to :tenant, optional: true

  validates :email, presence: true, uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true

  enum :role, { admin: "admin", super_admin: "super_admin" }, default: :admin
end
