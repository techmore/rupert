# frozen_string_literal: true

# Aggregates accounts payable (what we owe vendors) and accounts receivable
# (what customers owe us) for the Accounts screens.
class AccountsService
  class << self
    # Per-vendor AP: received PO value minus payments made.
    def payable_by_vendor
      rows = Purchasing::Vendor.left_joins(:purchase_orders)
        .where(purchase_orders: { status: ["ordered", "received"] })
        .group("vendors.id", "vendors.name")
        .select(
          "vendors.id",
          "vendors.name",
          "COALESCE(SUM(CASE WHEN purchase_orders.status = 'received' THEN
             (SELECT COALESCE(SUM(purchase_order_lines.received_quantity * purchase_order_lines.unit_cost_cents), 0)
              FROM purchase_order_lines
              WHERE purchase_order_lines.purchase_order_id = purchase_orders.id) ELSE 0 END), 0) AS owed_cents",
          "COALESCE(SUM(CASE WHEN purchase_orders.status = 'ordered' THEN
             (SELECT COALESCE(SUM(purchase_order_lines.quantity * purchase_order_lines.unit_cost_cents), 0)
              FROM purchase_order_lines
              WHERE purchase_order_lines.purchase_order_id = purchase_orders.id) ELSE 0 END), 0) AS committed_cents",
        )

      payments = Finance::VendorPayment.group(:vendor_id).sum(:amount_cents)

      rows.map do |row|
        paid = payments.fetch(row.id, 0)
        {
          vendor: row,
          owed_cents: row.owed_cents.to_i,
          committed_cents: row.committed_cents.to_i,
          paid_cents: paid,
          balance_cents: [row.owed_cents.to_i - paid, 0].max,
        }
      end.sort_by { |r| -r[:balance_cents] }
    end

    def payable_total_cents
      payable_by_vendor.sum { |r| r[:balance_cents] }
    end

    # Per-customer AR: what's still unpaid across their orders. Two grouped
    # queries (gross per customer, paid per customer) — no per-order correlated
    # subqueries.
    def receivable_by_customer
      rows = Core::Customer.joins(:orders)
        .where(orders: { status: ["paid", "fulfilled"] })
        .group("customers.id", "customers.first_name", "customers.last_name", "customers.email", "customers.phone")
        .select(
          "customers.id",
          "customers.first_name",
          "customers.last_name",
          "customers.email",
          "customers.phone",
          "SUM(orders.gross_cents) AS gross_cents",
          "COUNT(orders.id) AS order_count",
        )

      paid_by_customer = Core::Payment.where(status: "completed")
        .joins(:order)
        .where(orders: { status: ["paid", "fulfilled"] })
        .group("orders.customer_id")
        .sum(:amount_cents)

      rows.filter_map do |row|
        paid = paid_by_customer.fetch(row.id, 0)
        balance = row.gross_cents.to_i - paid
        next if balance <= 0

        {
          customer: row,
          balance_cents: balance,
          paid_cents: paid,
          order_count: row.order_count,
        }
      end.sort_by { |r| -r[:balance_cents] }
    end

    def receivable_total_cents
      receivable_by_customer.sum { |r| r[:balance_cents] }
    end
  end
end
