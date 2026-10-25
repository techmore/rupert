# frozen_string_literal: true

module Mcp
  module Tools
    # "How is marketing doing?" One snapshot of the Marketing and Influencers
    # pages for a period: reply reviews, live offers and codes, gifts sent,
    # the influencer pipeline and what is waiting on someone.
    class MarketingSummary < Tool
      SOON_DAYS = 14

      tool 'marketing_summary',
        title: 'Marketing summary',
        description: 'How marketing is doing for a period (default this month) and what needs attention now: community replies ' \
                     'drafted, approved and published, and replies waiting for review; offers and discount codes live now, starting ' \
                     'or ending soon; Shopify influencer codes by status; free product gifted to influencers (gifts shipped, units, ' \
                     'product and shipping cost); the influencer pipeline by stage and follow-ups due; collaborations active and due ' \
                     'soon; new community threads to triage; marketing changes made. Read-only. For lists of the records use ' \
                     'marketing_records. NOT stored in Rupert: customer product reviews or star ratings, discount code usage or revenue, ' \
                     'campaign dates, budgets or results, event calendars, email/social/web analytics.',
        scope: 'marketing:read'

      input_schema(
        type: 'object',
        properties: {
          from: DATE_PROPERTY.merge(description: 'Start date, YYYY-MM-DD. Default the first of this month.'),
          to: DATE_PROPERTY.merge(description: 'End date, YYYY-MM-DD, inclusive. Default today.')
        },
        additionalProperties: false
      )

      def call(args)
        from, to = date_range(args, default_from: Date.current.beginning_of_month)
        @now = Time.current
        @period = from.in_time_zone.beginning_of_day..to.in_time_zone.end_of_day
        @soon = @now..SOON_DAYS.days.from_now
        data = { from: from.iso8601, to: to.iso8601, marketing_enabled: FeatureFlag.enabled?(:marketing),
                 replies: replies, offers: offers, discounts: discounts, gifts: gifts, influencers: influencers,
                 engagements: engagements, threads: threads, changes_made: Marketing::CmsEvent.where(created_at: @period).count,
                 not_stored: ['customer product reviews and star ratings', 'discount code usage and revenue',
                              'campaign dates, budgets and results', 'event calendars', 'email, social and web analytics'] }
        result(text(data), data)
      end

      private

      def replies
        period = Marketing::Reply.where(created_at: @period)
        { drafted: period.count, published: Marketing::Reply.where(published_at: @period).count,
          approvals: Marketing::ReviewEvent.where(created_at: @period, action: 'approve').count,
          rejections: Marketing::ReviewEvent.where(created_at: @period, action: %w[reject changes]).count,
          pending_review_now: Marketing::Reply.where(status: 'pending_review').count,
          approved_not_published_now: Marketing::Reply.where(status: 'approved').count }
      end

      def offers
        active = Marketing::Offer.where(starts_at: ..@now).where(ends_at: @now..)
        { active_now: active.count, active_community: active.where.not(community_id: nil).count,
          active_influencer: active.where.not(engagement_id: nil).count,
          active_codes: active.order(:ends_at).limit(10).pluck(:code),
          ending_soon: Marketing::Offer.where(ends_at: @soon).count, starting_soon: Marketing::Offer.where(starts_at: @soon).count,
          ran_in_period: Marketing::Offer.where(starts_at: ..@period.end).where(ends_at: @period.begin..).count }
      end

      def discounts
        { by_status: Marketing::ShopifyDiscount.group(:status).count,
          created_in_period: Marketing::ShopifyDiscount.where(created_at: @period).count,
          needs_check: Marketing::ShopifyDiscount.where(status: %w[uncertain failed blocked]).count }
      end

      def gifts
        shipped = Marketing::ProductGift.includes(:items).where(shipped_at: @period).to_a
        totals = shipped.group_by(&:currency).map do |currency, rows|
          product = rows.filter_map(&:estimated_product_cents).sum
          shipping = rows.sum { |gift| gift.shipping_cost_cents.to_i }
          { currency: currency, gifts: rows.size, units: rows.sum { |gift| gift.items.to_a.sum(&:quantity) },
            product_cost_cents: product, product_cost_dollars: money(product), shipping_cost_cents: shipping,
            shipping_cost_dollars: money(shipping), gifts_missing_cost: rows.count { |gift| gift.estimated_product_cents.nil? } }
        end
        { shipped_in_period: totals, delivered_in_period: Marketing::ProductGift.where(delivered_at: @period).count,
          waiting_to_ship_now: Marketing::ProductGift.where(status: %w[proposed approved ready_to_ship]).group(:status).count }
      end

      def influencers
        contactable = Marketing::Influencer.where.not(stage: %w[declined do_not_contact])
        { by_stage: Marketing::Influencer.group(:stage).count, added_in_period: Marketing::Influencer.where(created_at: @period).count,
          follow_ups_due_now: contactable.where(next_follow_up_at: ..@now).count }
      end

      def engagements
        active = Marketing::Engagement.where(status: 'active')
        { by_status: Marketing::Engagement.group(:status).count, overdue_now: active.where(due_at: ...@now).count,
          due_soon: active.where(due_at: @soon).count, completed_in_period: Marketing::Engagement.where(status: 'completed', updated_at: @period).count }
      end

      def threads
        { new_to_triage: Marketing::Thread.where(status: 'new').count, found_in_period: Marketing::Thread.where(created_at: @period).count }
      end

      def text(data)
        replies = data[:replies]
        offers = data[:offers]
        lines = ["Marketing #{data[:from]} to #{data[:to]}: #{replies[:published]} replies published, #{replies[:drafted]} drafted, " \
                 "#{replies[:pending_review_now]} waiting for review; #{offers[:active_now]} offers live now" \
                 "#{" (#{offers[:active_codes].join(', ')})" if offers[:active_codes].any?}, #{offers[:ending_soon]} ending within #{SOON_DAYS} days."]
        data[:gifts][:shipped_in_period].each do |row|
          lines << "Gifts shipped: #{row[:gifts]} (#{row[:units]} units, product #{row[:product_cost_dollars]} #{row[:currency]}, shipping #{row[:shipping_cost_dollars]} #{row[:currency]})."
        end
        lines << 'No gifts shipped.' if data[:gifts][:shipped_in_period].empty?
        lines << "Influencers: #{data[:influencers][:follow_ups_due_now]} follow-ups due; #{data[:engagements][:by_status].fetch('active', 0)} active collaborations " \
                 "(#{data[:engagements][:overdue_now]} overdue). #{data[:threads][:new_to_triage]} new threads to triage."
        lines << "#{data[:discounts][:needs_check]} Shopify codes need a check." if data[:discounts][:needs_check].positive?
        lines << 'Product reviews, ratings and discount usage are not stored in Rupert.'
        lines << 'Marketing is turned off in this workspace.' unless data[:marketing_enabled]
        lines.join(' ')
      end
    end
  end
end
