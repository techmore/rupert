# frozen_string_literal: true

module CtraxHelper
  def ctrax_money(value, currency: 'USD')
    Money.format(value, currency: currency, minus: '-')
  end
end
