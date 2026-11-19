# frozen_string_literal: true

require 'test_helper'

# How a card was presented is one word from a fixed list, or NULL when it was never recorded.
class PaymentEntryMethodTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  REFUSED = ['Contactless', 'TAP', 'tap ', '', 'tap-on-phone', 'contactless', '4111111111111111'].freeze

  test 'the list is fixed and every word but unknown has receipt wording' do
    assert_equal %w[tap chip swipe keyed unknown], PaymentEntryMethod::VALUES
    assert_equal %w[Contactless Chip Swipe Keyed], %w[tap chip swipe keyed].map { |value| PaymentEntryMethod.label(value) }
    [nil, 'unknown', 'Contactless', ''].each { |value| assert_nil PaymentEntryMethod.label(value) }
  end

  test 'a payment attempt accepts the listed words or nothing' do
    attempt = PosPaymentAttempt.new
    ([nil] + PaymentEntryMethod::VALUES).each do |value|
      attempt.entry_method = value
      attempt.valid?
      assert_empty attempt.errors[:entry_method], value.inspect
    end
    REFUSED.each do |value|
      attempt.entry_method = value
      attempt.valid?
      assert_not_empty attempt.errors[:entry_method], value.inspect
    end
  end

  test 'a payment accepts the listed words or nothing' do
    payment = Core::Payment.new
    ([nil] + PaymentEntryMethod::VALUES).each do |value|
      payment.entry_method = value
      payment.valid?
      assert_empty payment.errors[:entry_method], value.inspect
    end
    REFUSED.each do |value|
      payment.entry_method = value
      payment.valid?
      assert_not_empty payment.errors[:entry_method], value.inspect
    end
  end

  test 'both columns are nullable strings with no default, so existing rows stay unrecorded' do
    [PosPaymentAttempt, Core::Payment].each do |model|
      column = model.columns_hash.fetch('entry_method')
      assert_equal [:string, true, nil], [column.type, column.null, column.default], model.name
    end
  end
end
