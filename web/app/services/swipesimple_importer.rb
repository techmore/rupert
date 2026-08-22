# frozen_string_literal: true

require 'csv'

# Imports sales from a SwipeSimple CSV export (SwipeSimple has no public API,
# so the Reporting Dashboard's CSV export is the integration seam). Handles
# order-level or line-level layouts with flexible column names, and is
# idempotent: re-importing the same file upserts rather than duplicates.
#
# Expected columns (aliases accepted, case/space/underscore-insensitive):
#   order/receipt/invoice id · date/time · item/product name · sku · quantity ·
#   unit price · line total (or order total) · payment method · customer
class SwipesimpleImporter
  Result = Struct.new(:orders, :lines, :payments, :skipped_rows, keyword_init: true)

  COLUMN_ALIASES = {
    order_id: %w[orderid order id invoice invoiceid receipt receiptid transactionid
                 transaction],
    order_number: %w[ordernumber ordernum receiptnumber invoicenumber],
    date: %w[date datetime datetime date_time saledate transactiondate paidat createdat
             created time],
    item: %w[item itemname product productname name description itemdescription title],
    sku: %w[sku itemsku productsku upc itemcode code],
    quantity: %w[quantity qty count qtysold units],
    unit_price: %w[unitprice price unitcost unitamount amounteach saleprice],
    line_total: %w[total amount linetotal linetotalamount gross linamount],
    order_total: %w[ordertotal grandtotal totalamount receipttotal],
    payment: %w[payment paymentmethod method tender tendertype cardbrand paymenttype],
    customer: %w[customer customername name firstname lastname],
    status: %w[status salestatus]
  }.freeze

  class << self
    # Import CSV text (or a path). Returns a Result summary.
    def import!(csv_text_or_path)
      rows, headers = parse_rows(csv_text_or_path)
      return Result.new(orders: 0, lines: 0, payments: 0, skipped_rows: 0) if rows.empty?

      by_order = group_by_order(rows, headers)
      summary = Result.new(orders: 0, lines: 0, payments: 0, skipped_rows: 0)

      by_order.each do |order_id, order_rows|
        next summary.skipped_rows += order_rows.length if order_rows.all? do |row|
          row[headers[:date]].blank? && row[headers[:item]].blank?
        end

        upsert_order!(order_id, order_rows, headers)
        summary.orders += 1
        summary.lines += order_rows.length
      end
      summary
    end

    private

    # Reads the CSV and maps each physical header to a canonical column key.
    def parse_rows(source)
      text = source.respond_to?(:read) ? source.read : source.to_s
      table = CSV.parse(text, headers: true)
      return [[], {}] if table.headers.empty?

      mapping = {}
      table.headers.each do |header|
        key = canonical_key(header)
        next if key.nil?

        mapping[key] = header
      end
      [table.map { |row| row }, mapping]
    end

    def canonical_key(header)
      normalized = header.to_s.downcase.gsub(/[^a-z0-9]/, '')
      COLUMN_ALIASES.each do |key, aliases|
        return key if aliases.include?(normalized)
      end
      nil
    end

    # Groups rows into orders. Rows without an order id become their own order
    # keyed by a stable hash so re-imports stay idempotent.
    def group_by_order(rows, headers)
      id_header = headers[:order_id]
      rows.group_by do |row|
        raw = id_header && row[id_header]
        raw.to_s.strip.presence || synthetic_id(row, headers)
      end
    end

    def synthetic_id(row, headers)
      date = value(row, headers[:date])
      gross = money_to_cents(value(row, headers[:order_total] || headers[:line_total]))
      item = value(row, headers[:item]).to_s
      Digest::MD5.hexdigest("#{date}|#{gross}|#{item}")[0, 16]
    end

    def upsert_order!(order_id, order_rows, headers)
      first = order_rows.first
      occurred_at = parse_date(value(first, headers[:date])) || Time.current
      customer = upsert_customer!(first, headers)
      gross = order_gross_cents(order_rows, headers)
      order_number = value(first, headers[:order_number]).presence || "SS-#{order_id.to_s.slice(0, 12)}"

      Core::Order.upsert(
        {
          tenant_id: Current.tenant_id,
          source: 'swipesimple',
          source_order_id: order_id.to_s,
          order_number: order_number,
          channel: 'pos',
          customer_id: customer&.id,
          occurred_at: occurred_at,
          gross_cents: gross,
          tax_cents: 0,
          status: 'paid',
          line_items: order_rows.length,
          currency: 'USD',
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: %i[tenant_id source source_order_id]
      )

      order = Core::Order.find_by(tenant_id: Current.tenant_id, source: 'swipesimple', source_order_id: order_id.to_s)
      replace_lines!(order, order_rows, headers)
      replace_payments!(order, order_rows, headers, gross)
      upsert_ledger!(order, order_rows, headers, gross, occurred_at)
    end

    def upsert_customer!(row, headers)
      name = value(row, headers[:customer]).to_s.strip
      return if name.blank?

      first_name, last_name = name.split(/\s+/, 2)
      Core::Customer.upsert(
        {
          tenant_id: Current.tenant_id,
          source: 'swipesimple',
          external_id: name.downcase.gsub(/\s+/, '-'),
          first_name: first_name,
          last_name: last_name,
          email: nil,
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: %i[tenant_id source external_id]
      )
      Core::Customer.find_by(tenant_id: Current.tenant_id, source: 'swipesimple',
                             external_id: name.downcase.gsub(/\s+/, '-'))
    end

    def replace_lines!(order, rows, headers)
      order.order_lines.delete_all
      rows.each do |row|
        quantity = [value(row, headers[:quantity]).to_i, 0].max
        quantity = 1 if quantity.zero?
        unit_cents = money_to_cents(value(row, headers[:unit_price]))
        line_cents = money_to_cents(value(row, headers[:line_total]))
        line_cents = unit_cents * quantity if line_cents.zero? && unit_cents.positive?

        order.order_lines.create!(
          tenant_id: Current.tenant_id,
          sku: value(row, headers[:sku]).presence,
          name: value(row, headers[:item]).presence || 'Item',
          quantity: quantity,
          unit_cents: unit_cents,
          line_cents: line_cents
        )
      end
    end

    # One payment per distinct method on the order, totaling the gross.
    def replace_payments!(order, rows, headers, gross)
      order.payments.delete_all
      methods = rows.map { |row| normalize_method(value(row, headers[:payment])) }
      methods = ['card'] if methods.compact.empty?
      methods.uniq.each do |method|
        order.payments.create!(
          tenant_id: Current.tenant_id,
          method: method,
          amount_cents: gross,
          status: 'completed',
          reference: order.source_order_id,
          paid_at: order.occurred_at
        )
      end
    end

    def upsert_ledger!(order, rows, headers, gross, occurred_at)
      LedgerEntry.upsert(
        {
          id: "swipesimple:#{order.source_order_id}",
          source: 'swipesimple',
          sourceOrderId: order.source_order_id,
          orderName: order.order_number,
          occurredAt: occurred_at,
          syncedAt: Time.current,
          currency: 'USD',
          grossCents: gross,
          status: 'COMPLETED',
          lineItems: rows.sum { |row| [value(row, headers[:quantity]).to_i, 1].max },
          summary: rows.first(3).filter_map { |row| value(row, headers[:item]).presence }.join(', ')
        },
        unique_by: :id
      )
    end

    def order_gross_cents(rows, headers)
      totals = rows.filter_map { |row| money_to_cents(value(row, headers[:order_total])) }.select(&:positive?)
      return totals.first if totals.any?

      line = rows.sum { |row| money_to_cents(value(row, headers[:line_total])) }
      return line if line.positive?

      rows.sum do |row|
        quantity = [value(row, headers[:quantity]).to_i, 1].max
        money_to_cents(value(row, headers[:unit_price])) * quantity
      end
    end

    def normalize_method(raw)
      case raw.to_s.strip.downcase
      when 'cash' then 'cash'
      when 'gift', 'gift card', 'giftcard' then 'gift_card'
      when '', 'n/a', 'na' then nil
      else 'card'
      end
    end

    def value(row, header)
      return '' if header.nil?

      row[header]
    end

    def money_to_cents(raw)
      # CSV cells are often blank (missing columns, empty cells); callers sum
      # and multiply the result, so blanks coerce to 0 instead of nil.
      Money.cents_from_amount(raw).to_i
    end

    def parse_date(raw)
      return if raw.blank?

      text = raw.to_s.strip
      formats = [
        '%m/%d/%Y %I:%M %p',
        '%m/%d/%Y %I:%M%p',
        '%m/%d/%Y',
        '%m/%d/%y',
        '%m-%d-%Y'
      ]
      formats.each do |format|
        parsed = Time.zone.strptime(text, format)
        return parsed
      rescue ArgumentError
        next
      end
      Time.zone.parse(text)
    rescue ArgumentError
      nil
    end
  end
end
