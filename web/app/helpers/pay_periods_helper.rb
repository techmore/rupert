# frozen_string_literal: true

# time & pay: manager. Pills and figures shared by the pay periods and approvals pages.
module PayPeriodsHelper
  PAY_PERIOD_STATUSES = { 'open' => ['Open', 'pill-taupe'], 'locked' => ['Locked', 'pill-olive'], 'exported' => ['Exported', 'pill-fern'] }.freeze

  def pay_period_status_pill(period)
    label, pill = PAY_PERIOD_STATUSES.fetch(period.status, [period.status.humanize, 'pill-taupe'])
    tag.span(label, class: pill, data: { pay_period_status: period.status })
  end

  def cents(amount)
    number_to_currency(amount.to_i / 100.0)
  end

  def hours_cell(value)
    value.to_d.zero? ? '–' : format('%.2f', value.to_d)
  end
end
