# frozen_string_literal: true

# Global search across the ERP: orders, customers, and SKUs. Returns a small,
# ranked list of results for the command-palette dropdown.
class SearchService
  Result = Struct.new(:type, :label, :sub_label, :path, keyword_init: true)

  class << self
    def search(query, limit: 8)
      term = query.to_s.strip
      return [] if term.length < 2

      results = []
      results.concat(search_orders(term))
      results.concat(search_customers(term))
      results.concat(search_variants(term))
      results.concat(search_employees(term))
      results.first(limit)
    end

    private

    def search_orders(term)
      Core::Order.where(tenant_id: Current.tenant_id)
        .where("order_number ILIKE ? OR source_order_id ILIKE ?", "%#{term}%", "%#{term}%")
        .order(occurred_at: :desc)
        .limit(5)
        .map do |order|
          Result.new(
            type: "order",
            label: order.display_number,
            sub_label: "#{order.channel} · #{number(order.gross_cents / 100.0)}",
            path: Rails.application.routes.url_helpers.order_path(order),
          )
        end
    end

    def search_customers(term)
      Core::Customer.where(tenant_id: Current.tenant_id)
        .where(
          "first_name ILIKE :q OR last_name ILIKE :q OR email ILIKE :q OR phone ILIKE :q",
          q: "%#{term}%",
        )
        .order(:first_name)
        .limit(5)
        .map do |customer|
          Result.new(
            type: "customer",
            label: customer.name,
            sub_label: customer.email.presence || customer.phone.presence || customer.source,
            path: Rails.application.routes.url_helpers.customer_path(customer),
          )
        end
    end

    def search_variants(term)
      ShopifyVariant.where(tenant_id: Current.tenant_id)
        .where("\"ShopifyVariant\".sku ILIKE ? OR \"ShopifyVariant\".title ILIKE ?", "%#{term}%", "%#{term}%")
        .joins(:product)
        .order(:sku)
        .limit(5)
        .map do |variant|
          Result.new(
            type: "sku",
            label: variant.sku.presence || variant.title,
            sub_label: "#{variant.product&.title} · #{number(variant.price.to_f)}",
            path: Rails.application.routes.url_helpers.shopify_variant_path(variant),
          )
        end
    end

    def search_employees(term)
      return [] unless Current.user&.can?("hr.read")

      People::Employee.where(tenant_id: Current.tenant_id)
        .where("first_name ILIKE :q OR last_name ILIKE :q OR employee_number ILIKE :q OR email ILIKE :q", q: "%#{term}%")
        .order(:last_name)
        .limit(5)
        .map do |employee|
          Result.new(
            type: "employee",
            label: employee.name,
            sub_label: employee.department&.name.presence || employee.position&.name.presence || employee.status.tr("_", " "),
            path: Rails.application.routes.url_helpers.people_employee_path(employee),
          )
        end
    end

    def number(value)
      ActiveSupport::NumberHelper.number_to_currency(value, unit: "$")
    end
  end
end
