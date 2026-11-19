# frozen_string_literal: true

# Refuses a change whose date falls inside a locked pay period (PayPeriod). Include it and name the
# date(s) the record carries:
#
#   include LockedPayPeriodGuard
#   guards_pay_period { [started_at&.to_date, ended_at&.to_date] }
#
# The check runs on create and on any change to the guarded dates, and the error reads the same
# everywhere so a manager knows to reopen the period or record an adjustment in the next one.
module LockedPayPeriodGuard
  extend ActiveSupport::Concern

  MESSAGE = 'falls in a locked pay period. Reopen the period or record the difference as an adjustment in the next one.'

  included do
    validate :pay_period_not_locked
  end

  class_methods do
    def guards_pay_period(&block)
      define_method(:guarded_pay_period_dates, &block)
    end
  end

  # True when any of `dates` sits inside a locked period.
  def self.locked?(dates)
    Array(dates).compact.map(&:to_date).uniq.any? { |date| !PayPeriod.open_for?(date) }
  end

  private

  def pay_period_not_locked
    return unless respond_to?(:guarded_pay_period_dates, true)
    return unless new_record? || guarded_dates_changed?

    dates = guarded_pay_period_dates
    return unless LockedPayPeriodGuard.locked?(dates)

    errors.add(:base, "This #{self.class.model_name.human.downcase} #{MESSAGE}")
  end

  # Subclasses may narrow which attribute changes trigger the check; by default any change does.
  def guarded_dates_changed?
    has_changes_to_save?
  end
end
