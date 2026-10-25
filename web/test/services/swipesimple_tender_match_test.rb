# frozen_string_literal: true

require 'test_helper'

class SwipesimpleTenderMatchTest < ActiveSupport::TestCase
  HEADER = 'Transaction #,Date,Type,Amount,Result,Method,Brand,Merchant Account,Tip Amount'
  DAY = Date.new(2026, 10, 14)

  setup do
    Current.tenant = tenants(:default_tenant)
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
  end

  teardown do
    travel_back
    Current.reset
  end

  test 'a lone tender and sale of the same amount within the window pair exactly' do
    import(['SYN-1,10/14/2026 9:00 AM,Sale,$50.00,Approved,Dipped,Visa,Example Wholesale,$5.00',
      'SYN-2,10/14/2026 9:30 AM,Sale,$12.00,Approved,Tapped,Visa,Example Wholesale,'])
    tender!(5000, '2026-10-14 09:03')
    tender!(1200, '2026-10-14 09:28')
    match = close.tender_match
    assert_equal [%w[SYN-1 5000], %w[SYN-2 1200]], match.pairs.map { |pair| [pair.row.source_number, pair.tender.amount_cents.to_s] }
    assert_equal 180, match.pairs.first.seconds_apart
    assert_empty match.unmatched_tenders
    assert_empty match.unmatched_rows
    assert_empty match.ambiguous
    assert match.all_matched?
  end

  test 'same amount with overlapping times is flagged as ambiguous and never paired' do
    import(['SYN-1,10/14/2026 9:00 AM,Sale,$20.00,Approved,Dipped,Visa,Example Wholesale,',
      'SYN-2,10/14/2026 9:04 AM,Sale,$20.00,Approved,Tapped,Visa,Example Wholesale,',
      'SYN-3,10/14/2026 3:00 PM,Sale,$20.00,Approved,Tapped,Visa,Example Wholesale,'])
    tender!(2000, '2026-10-14 09:01')
    tender!(2000, '2026-10-14 09:05')
    tender!(2000, '2026-10-14 15:02')
    match = close.tender_match
    assert_equal 1, match.ambiguous.size
    group = match.ambiguous.first
    assert_equal [2, 2, 2000], [group.tenders.size, group.rows.size, group.amount_cents]
    assert_equal ['SYN-3'], match.pairs.map { |pair| pair.row.source_number }, 'a separate afternoon sale still pairs'
    refute match.all_matched?

    import(['SYN-4,10/14/2026 9:02 AM,Sale,$7.00,Approved,Tapped,Visa,Example Wholesale,',
      'SYN-5,10/14/2026 9:06 AM,Sale,$7.00,Approved,Tapped,Visa,Example Wholesale,'], exported_at: '2026-10-15T23:00:00-04:00')
    tender!(700, '2026-10-14 09:04')
    seven = SwipesimpleDayClose.new(DAY).tender_match.ambiguous.find { |item| item.amount_cents == 700 }
    assert_equal [1, 2], [seven.tenders.size, seven.rows.size], 'one tender between two equal sales is not guessed'
  end

  test 'unmatched tenders and sales are listed on both sides with wrong amount or time' do
    import(['SYN-1,10/14/2026 9:00 AM,Sale,$50.00,Approved,Dipped,Visa,Example Wholesale,',
      'SYN-2,10/14/2026 1:00 PM,Sale,$30.00,Approved,Dipped,Visa,Example Wholesale,',
      'SYN-3,10/14/2026 2:00 PM,Sale,$40.00,Approved,Cash,,Example Wholesale,',
      'SYN-4,10/14/2026 2:30 PM,Sale,$45.00,Declined,Dipped,Visa,Example Wholesale,'])
    tender!(5001, '2026-10-14 09:00')
    tender!(3000, '2026-10-14 13:30')
    match = close.tender_match
    assert_empty match.pairs
    assert_equal [5001, 3000], match.unmatched_tenders.map(&:amount_cents)
    assert_equal %w[SYN-1 SYN-2], match.unmatched_rows.map(&:source_number), 'cash and declined rows are not card sales'
  end

  test 'a sale rung just before midnight pairs with a terminal stamp just after, on both days' do
    import(['SYN-1,10/14/2026 11:58 PM,Sale,$9.00,Approved,Dipped,Visa,Example Wholesale,',
      'SYN-2,10/15/2026 12:03 AM,Sale,$15.00,Approved,Dipped,Visa,Example Wholesale,'])
    tender!(900, '2026-10-15 00:02')
    tender!(1500, '2026-10-14 23:57')
    [DAY, DAY + 1].each do |day|
      match = SwipesimpleDayClose.new(day).tender_match
      assert_equal 2, match.pairs.size, "both cross-midnight pairs show on #{day}"
      assert_empty match.unmatched_tenders
      assert_empty match.unmatched_rows
    end
    match = SwipesimpleDayClose.new(DAY + 2).tender_match
    assert_empty match.pairs
    assert match.no_tenders?
  end

  test 'a day without Rupert card tenders says so and ignores cash and other sources' do
    import(['SYN-1,10/14/2026 9:00 AM,Sale,$50.00,Approved,Dipped,Visa,Example Wholesale,'])
    tender!(5000, '2026-10-14 09:00', method: 'cash')
    tender!(5000, '2026-10-14 09:00', source: 'shopify')
    match = close.tender_match
    assert match.no_tenders?
    assert_equal 1, match.day_rows.size
    assert_empty match.pairs
  end

  private

  def close
    SwipesimpleDayClose.new(DAY)
  end

  def tender!(cents, local_time, method: 'card', source: 'rupert_pos')
    at = ActiveSupport::TimeZone['America/New_York'].parse(local_time)
    @serial = @serial.to_i + 1
    order = Core::Order.create!(source: source, source_order_id: "synthetic-#{@serial}", order_number: "RP-#{@serial}",
      channel: 'pos', currency: 'USD', occurred_at: at, gross_cents: cents, tax_cents: 0, tip_cents: 0)
    order.payments.create!(method: method, amount_cents: cents, status: 'completed', paid_at: at, reference: "synthetic-#{@serial}")
  end

  def import(rows, exported_at: '2026-10-15T22:00:00-04:00')
    csv = ([HEADER] + rows).join("\n") + "\n"
    options = { kind: 'transactions', merchant_account: 'Example Wholesale', currency: 'USD',
      source_timezone: 'America/New_York', exported_at: exported_at }
    prepared = SwipesimpleReportImporter.preview(csv, options)
    SwipesimpleReportImporter.import!(csv, options, expected_fingerprint: prepared.fingerprint)
  end
end
