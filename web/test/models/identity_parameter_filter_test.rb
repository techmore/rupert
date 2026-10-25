# frozen_string_literal: true

require 'test_helper'

class IdentityParameterFilterTest < ActiveSupport::TestCase
  test 'tax and identity fields are filtered without over-filtering lookalike keys' do
    original = {
      'vendor' => { 'tin' => '12-3456789', 'legal_name' => 'Acme Holdings LLC', 'address' => '1 Main St',
                    'address_line1' => '1 Main St', 'address_line2' => 'Suite 2', 'postal_code' => '02101', 'name' => 'Acme' },
      'employee' => { 'date_of_birth' => '1990-01-01', 'first_name' => 'Pat' },
      'tint' => 'blue', 'address_verified' => 'true', 'email_address_id' => '7', 'postal_code_hint' => 'zip', 'legal_name_note' => 'x'
    }
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(original)
    %w[tin legal_name address address_line1 address_line2 postal_code].each do |key|
      assert_equal '[FILTERED]', filtered.dig('vendor', key), "not filtered: #{key}"
    end
    assert_equal '[FILTERED]', filtered.dig('employee', 'date_of_birth')
    assert_equal 'Acme', filtered.dig('vendor', 'name')
    assert_equal 'Pat', filtered.dig('employee', 'first_name')
    %w[tint address_verified email_address_id postal_code_hint legal_name_note].each do |key|
      assert_equal original[key], filtered[key], "over-filtered: #{key}"
    end
  end
end
