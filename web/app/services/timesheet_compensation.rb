# frozen_string_literal: true

# Calculates the compensation figures shown on a timesheet:
#   - commission: PayRules.commission_cents (1%) of credited period sales
#   - card bonus: a fixed bonus per employee 50%-off card redemption
#
# Display figures only. This does not post to payroll and does not create payslips.
class TimesheetCompensation
  COMMISSION_RATE = PayRules::COMMISSION_RATE
  CARD_BONUS_CENTS = 1000

  def self.calculate(sales_cents:, card_redemptions:)
    sales = sales_cents.to_i
    redemptions = card_redemptions.to_i
    commission = PayRules.commission_cents(sales)
    bonus = redemptions * CARD_BONUS_CENTS
    { sales_cents: sales, commission_cents: commission, card_redemptions: redemptions,
      card_bonus_cents: bonus, total_cents: commission + bonus }
  end
end
