# frozen_string_literal: true

module Mcp
  module Tools
    # Lists the records behind the Marketing and Influencers pages, one kind at a
    # time, with counts per status. Private influencer contact fields, shipping
    # details, tracking numbers and audit payloads are never returned.
    class MarketingRecords < Tool
      KINDS = %w[campaigns communities offers discounts reviews influencers engagements gifts events].freeze
      OFFER_STATES = %w[scheduled active ended].freeze
      RULE_STATES = %w[rules_current rules_need_check].freeze
      REPLY_STATUSES = %w[draft pending_review approved published rejected removed].freeze
      STATUSES = {
        'communities' => RULE_STATES,
        'offers' => OFFER_STATES,
        'discounts' => Marketing::ShopifyDiscount::STATUSES,
        'reviews' => REPLY_STATUSES,
        'influencers' => Marketing::Influencer::STAGES,
        'engagements' => Marketing::Engagement::STATUSES,
        'gifts' => Marketing::ProductGift::STATUSES
      }.freeze
      DATE_FIELDS = {
        'campaigns' => 'created', 'communities' => 'created', 'offers' => 'running at any point in the range',
        'discounts' => 'created', 'reviews' => 'reply drafted', 'influencers' => 'added', 'engagements' => 'created',
        'gifts' => 'shipped (or created, if not shipped yet)', 'events' => 'recorded'
      }.freeze

      tool 'marketing_records',
        title: 'Marketing records',
        description: 'Lists Rupert Marketing and Influencer records, one kind at a time, with counts per status. Kinds: ' \
                     'campaigns (name, storefront, topics, and how many groups, offers, collaborations, gifts and published replies each has); ' \
                     'communities (online groups/forums we post in, rules check, threads per status); ' \
                     'offers (discount codes shared with a group or an influencer: code, terms, start/end, scheduled/active/ended, verified); ' \
                     'discounts (influencer codes created in Shopify from Rupert: status, Shopify status, % or amount off, usage limit, dates); ' \
                     'reviews (our community replies and their approval review: draft, pending_review, approved, published, rejected, removed); ' \
                     'influencers (creator pipeline by stage, platform, owner, next follow-up); ' \
                     'engagements (influencer collaborations: status, due date, deliverables); ' \
                     'gifts (free product sent to influencers: items, units, product cost, shipping cost, ship/deliver dates); ' \
                     'events (the marketing change history: who changed which influencer, gift, offer, discount or document, and when). ' \
                     'Optional text query, status filter, date range and paging. Read-only. NOT stored in Rupert: customer product reviews ' \
                     'or star ratings, how many times a discount code was used or the revenue it drove, campaign start/end dates, budgets ' \
                     'or results, influencer post performance, event calendars, community member counts, email/social/web analytics. ' \
                     'Influencer emails, shipping addresses and private notes are never shown.',
        scope: 'marketing:read'

      input_schema(
        type: 'object',
        properties: {
          kind: { type: 'string', enum: KINDS, description: 'Which records to list.' },
          query: { type: 'string', maxLength: 100, description: 'Text to match: names, codes, terms, handles, product names or SKUs, depending on kind.' },
          status: { type: 'string', enum: STATUSES.values.flatten.uniq,
                    description: 'Only this status. offers: scheduled/active/ended. communities: rules_current/rules_need_check. ' \
                                 'discounts: draft/creating/created/uncertain/failed/blocked. reviews: reply status. ' \
                                 'influencers: stage. engagements and gifts: their status. Campaigns and events have no status.' },
          from: DATE_PROPERTY.merge(description: 'Start date, YYYY-MM-DD. Optional; default is all time.'),
          to: DATE_PROPERTY.merge(description: 'End date, YYYY-MM-DD, inclusive. Optional; default today when from is given.'),
          **PAGE_PROPERTIES
        },
        required: ['kind'],
        additionalProperties: false
      )

      def call(args)
        kind = args['kind'].to_s
        raise ToolError.new("kind must be one of: #{KINDS.join(', ')}.", kind: 'invalid_arguments') unless KINDS.include?(kind)

        status = args['status'].presence
        if status && !STATUSES.fetch(kind, []).include?(status)
          valid = STATUSES[kind]
          message = valid ? "status for #{kind} must be one of: #{valid.join(', ')}." : "#{kind.capitalize} have no status; leave status out."
          raise ToolError.new(message, kind: 'invalid_arguments')
        end
        @now = Time.current
        @query = args['query'].to_s.strip.downcase.presence
        @range = time_range(args)
        rows, meta, counts, totals = public_send(:"list_#{kind}", status, args)
        data = { kind: kind, marketing_enabled: FeatureFlag.enabled?(:marketing), status: status,
                 from: @range&.begin&.to_date&.iso8601, to: @range&.end&.to_date&.iso8601, date_filter: (DATE_FIELDS[kind] if @range),
                 counts: counts, totals: totals, rows: rows, meta: meta }.compact
        result(summary(kind, status, counts, rows, meta, totals, data[:marketing_enabled]), data)
      end

      def list_campaigns(_status, args)
        scope = Marketing::Campaign.all
        scope = like(scope, %w[marketing_campaigns.name marketing_campaigns.topics])
        scope = dated(scope, 'marketing_campaigns.created_at')
        campaigns, meta = paginate(scope.order(:name, :id), args)
        ids = campaigns.map(&:id)
        communities = Marketing::Community.where(campaign_id: ids).group(:campaign_id).count
        engagements = Marketing::Engagement.where(campaign_id: ids).group(:campaign_id).count
        group_offers = Marketing::Offer.joins(:community).where(marketing_communities: { campaign_id: ids }).group('marketing_communities.campaign_id').count
        creator_offers = Marketing::Offer.joins(:engagement).where(marketing_engagements: { campaign_id: ids }).group('marketing_engagements.campaign_id').count
        gifts = Marketing::ProductGift.joins(:engagement).where(marketing_engagements: { campaign_id: ids }).group('marketing_engagements.campaign_id').count
        published = Marketing::Reply.where(status: 'published').joins(thread: :community)
          .where(marketing_communities: { campaign_id: ids }).group('marketing_communities.campaign_id').count
        rows = campaigns.map do |campaign|
          { id: campaign.id, name: campaign.name, storefront_url: campaign.storefront_url, topics: clip(campaign.topics, 300),
            communities: communities.fetch(campaign.id, 0), engagements: engagements.fetch(campaign.id, 0),
            offers: group_offers.fetch(campaign.id, 0) + creator_offers.fetch(campaign.id, 0), gifts: gifts.fetch(campaign.id, 0),
            published_replies: published.fetch(campaign.id, 0), created_at: iso(campaign.created_at) }
        end
        [rows, meta, { 'total' => scope.count }, nil]
      end

      def list_communities(status, args)
        scope = Marketing::Community.includes(:campaign)
        scope = like(scope, %w[marketing_communities.name marketing_communities.url])
        scope = dated(scope, 'marketing_communities.created_at')
        current = scope.where(rules_checked_at: 30.days.ago..@now)
        counts = { 'rules_current' => current.count, 'rules_need_check' => scope.count - current.count }
        scope = scope.where(id: current.select(:id)) if status == 'rules_current'
        scope = scope.where.not(id: current.select(:id)) if status == 'rules_need_check'
        communities, meta = paginate(scope.order(:name, :id), args)
        ids = communities.map(&:id)
        threads = Marketing::Thread.where(community_id: ids).group(:community_id, :status).count
        offers = Marketing::Offer.where(community_id: ids).group(:community_id).count
        rows = communities.map do |community|
          { id: community.id, name: community.name, url: community.url, campaign: community.campaign&.name,
            rules_checked_at: iso(community.rules_checked_at), rules_current: community.rules_current? ? true : false,
            threads: threads.select { |(id, _), _| id == community.id }.to_h { |(_, state), count| [state, count] },
            offers: offers.fetch(community.id, 0) }
        end
        [rows, meta, counts, nil]
      end

      def list_offers(status, args)
        scope = Marketing::Offer.includes(:shopify_discount, community: :campaign, engagement: %i[campaign influencer])
        scope = like(scope, %w[marketing_offers.code marketing_offers.terms])
        scope = scope.where(starts_at: ..@range.end).where(ends_at: @range.begin..) if @range
        counts = { 'scheduled' => scope.where(starts_at: @now..).count, 'active' => scope.where(starts_at: ..@now).where(ends_at: @now..).count,
                   'ended' => scope.where(ends_at: ...@now).count }
        scope = case status
        when 'scheduled' then scope.where(starts_at: @now..)
        when 'active' then scope.where(starts_at: ..@now).where(ends_at: @now..)
        when 'ended' then scope.where(ends_at: ...@now)
        else scope
        end
        offers, meta = paginate(scope.order(ends_at: :desc, id: :desc), args)
        rows = offers.map do |offer|
          { id: offer.id, code: offer.code, terms: clip(offer.terms, 400), state: offer_state(offer),
            for: offer.engagement_id ? 'influencer' : 'community',
            community: offer.community&.name, influencer: offer.engagement&.influencer&.name, engagement: offer.engagement&.title,
            campaign: offer.campaign&.name, starts_at: iso(offer.starts_at), ends_at: iso(offer.ends_at),
            verified_at: iso(offer.verified_at), shareable_now: offer.shareable? ? true : false,
            shopify_discount_status: offer.shopify_discount&.status, destination_url: offer.destination_url }
        end
        [rows, meta, counts, nil]
      end

      def list_discounts(status, args)
        scope = Marketing::ShopifyDiscount.joins(:offer).includes(offer: { engagement: :influencer })
        scope = like(scope, %w[marketing_offers.code])
        scope = dated(scope, 'marketing_shopify_discounts.created_at')
        counts = scope.group('marketing_shopify_discounts.status').count
        scope = scope.where(status: status) if status
        discounts, meta = paginate(scope.order(created_at: :desc, id: :desc), args)
        rows = discounts.map do |discount|
          input = discount_input(discount)
          { id: discount.id, code: discount.offer.code, influencer: discount.offer.engagement&.influencer&.name,
            status: discount.status, shopify_status: discount.remote_status, ready_to_share: discount.ready? ? true : false,
            benefit: benefit(input, discount.currency), minimum_subtotal: input&.dig('minimumRequirement', 'subtotal', 'greaterThanOrEqualToSubtotal'),
            currency: discount.currency, usage_limit: input&.dig('usageLimit'), once_per_customer: input&.dig('appliesOncePerCustomer'),
            starts_at: input&.dig('startsAt'), ends_at: input&.dig('endsAt'), uses: 'not stored',
            checked_at: iso(discount.checked_at), problem: (clip(discount.last_error, 200) if discount.last_error.present?),
            shopify_admin_url: discount.admin_url, created_at: iso(discount.created_at) }.compact
        end
        [rows, meta, counts, nil]
      end

      def list_reviews(status, args)
        scope = Marketing::Reply.joins(:thread).includes(:offer, :review_events, thread: :community)
        scope = like(scope, %w[marketing_threads.title marketing_replies.body])
        scope = dated(scope, 'marketing_replies.created_at')
        counts = scope.group('marketing_replies.status').count
        scope = scope.where(status: status) if status
        order = status == 'pending_review' ? { updated_at: :asc, id: :asc } : { updated_at: :desc, id: :desc }
        replies, meta = paginate(scope.order(order), args)
        names = user_names(replies.flat_map { |reply| reply.review_events.map(&:actor_id) })
        rows = replies.map do |reply|
          last = reply.review_events.max_by { |event| [event.created_at, event.id] }
          { id: reply.id, status: reply.status, thread: reply.thread.title, thread_url: reply.thread.url,
            community: reply.thread.community&.name, offer_code: reply.offer&.code, reply: clip(reply.body, 300),
            last_review_action: last&.action, last_review_by: last && names[last.actor_id], last_review_at: iso(last&.created_at),
            review_steps: reply.review_events.size, published_url: reply.published_url, published_at: iso(reply.published_at),
            created_at: iso(reply.created_at), path: paths.marketing_reply_path(reply) }.compact
        end
        [rows, meta, counts, nil]
      end

      def list_influencers(status, args)
        scope = Marketing::Influencer.all
        scope = like(scope, %w[marketing_influencers.name marketing_influencers.handle marketing_influencers.platform marketing_influencers.topics])
        scope = dated(scope, 'marketing_influencers.created_at')
        counts = scope.group(:stage).count
        scope = scope.where(stage: status) if status
        influencers, meta = paginate(scope.order(Arel.sql('next_follow_up_at IS NULL'), :next_follow_up_at, :name, :id), args)
        ids = influencers.map(&:id)
        engagements = Marketing::Engagement.where(influencer_id: ids).group(:influencer_id).count
        gifts = Marketing::ProductGift.joins(:engagement).where(marketing_engagements: { influencer_id: ids }).group('marketing_engagements.influencer_id').count
        last_contact = Marketing::Interaction.where(influencer_id: ids).group(:influencer_id).maximum(:occurred_at)
        owners = user_names(influencers.map(&:owner_id))
        rows = influencers.map do |influencer|
          { id: influencer.id, name: influencer.name, platform: influencer.platform, handle: influencer.handle,
            profile_url: influencer.profile_url, topics: clip(influencer.topics, 200), stage: influencer.stage,
            owner: owners[influencer.owner_id], next_follow_up_at: iso(influencer.next_follow_up_at),
            follow_up_due: influencer.next_follow_up_at.present? && influencer.next_follow_up_at <= @now && influencer.contactable?,
            last_contact_at: iso(last_contact[influencer.id]), engagements: engagements.fetch(influencer.id, 0),
            gifts: gifts.fetch(influencer.id, 0), path: paths.marketing_influencer_path(influencer) }.compact
        end
        [rows, meta, counts, nil]
      end

      def list_engagements(status, args)
        scope = Marketing::Engagement.joins(:influencer).includes(:influencer, :campaign)
        scope = like(scope, %w[marketing_engagements.title marketing_influencers.name])
        scope = dated(scope, 'marketing_engagements.created_at')
        counts = scope.group('marketing_engagements.status').count
        scope = scope.where(status: status) if status
        engagements, meta = paginate(scope.order(Arel.sql('marketing_engagements.due_at IS NULL'), 'marketing_engagements.due_at', 'marketing_engagements.id'), args)
        ids = engagements.map(&:id)
        gifts = Marketing::ProductGift.where(engagement_id: ids).group(:engagement_id).count
        offers = Marketing::Offer.where(engagement_id: ids).group(:engagement_id).count
        rows = engagements.map do |engagement|
          { id: engagement.id, title: engagement.title, status: engagement.status, influencer: engagement.influencer.name,
            campaign: engagement.campaign&.name, due_at: iso(engagement.due_at),
            overdue: engagement.status == 'active' && engagement.due_at.present? && engagement.due_at < @now,
            deliverables: clip(engagement.deliverables, 300), gifts: gifts.fetch(engagement.id, 0), offers: offers.fetch(engagement.id, 0),
            created_at: iso(engagement.created_at), path: paths.marketing_engagement_path(engagement) }.compact
        end
        [rows, meta, counts, nil]
      end

      def list_gifts(status, args)
        scope = Marketing::ProductGift.joins(engagement: :influencer).includes(:items, engagement: :influencer)
        if @query
          term = "%#{Marketing::ProductGift.sanitize_sql_like(@query)}%"
          matching = Marketing::ProductGiftItem.where('LOWER(product_name) LIKE :q OR LOWER(sku) LIKE :q', q: term).select(:product_gift_id)
          scope = scope.where('LOWER(marketing_influencers.name) LIKE :q', q: term).or(scope.where(id: matching))
        end
        scope = scope.where('COALESCE(marketing_product_gifts.shipped_at, marketing_product_gifts.created_at) BETWEEN ? AND ?', @range.begin, @range.end) if @range
        counts = scope.group('marketing_product_gifts.status').count
        scope = scope.where(status: status) if status
        totals = gift_totals(scope)
        gifts, meta = paginate(scope.order(Arel.sql('COALESCE(marketing_product_gifts.shipped_at, marketing_product_gifts.created_at) DESC'), id: :desc), args)
        rows = gifts.map do |gift|
          product = gift.estimated_product_cents
          { id: gift.id, status: gift.status, influencer: gift.engagement.influencer.name, engagement: gift.engagement.title,
            items: gift.items.map { |item| { product: item.product_name, sku: item.sku, quantity: item.quantity, unit_cost_cents: item.unit_cost_cents } },
            units: gift.items.to_a.sum(&:quantity), currency: gift.currency,
            product_cost_cents: product, product_cost_dollars: (money(product) if product),
            shipping_cost_cents: gift.shipping_cost_cents, shipping_cost_dollars: (money(gift.shipping_cost_cents) if gift.shipping_cost_cents),
            carrier: gift.carrier, shipped_at: iso(gift.shipped_at), delivered_at: iso(gift.delivered_at), returned_at: iso(gift.returned_at),
            created_at: iso(gift.created_at), path: paths.marketing_product_gift_path(gift) }.compact
        end
        [rows, meta, counts, totals]
      end

      def list_events(_status, args)
        scope = Marketing::CmsEvent.includes(:actor)
        scope = like(scope, %w[marketing_cms_events.action marketing_cms_events.subject_type])
        scope = dated(scope, 'marketing_cms_events.created_at')
        counts = scope.group(:action).count
        events, meta = paginate(scope.order(created_at: :desc, id: :desc), args)
        labels = subject_labels(events)
        rows = events.map do |event|
          { id: event.id, at: iso(event.created_at), action: event.action, by: user_name(event.actor),
            subject: event.subject_type.delete_prefix('Marketing::').underscore.tr('_', ' '), subject_id: event.subject_id,
            subject_name: labels[[event.subject_type, event.subject_id]] }.compact
        end
        [rows, meta, counts, nil]
      end

      private

      def paths = Rails.application.routes.url_helpers

      def time_range(args)
        return if args['from'].blank? && args['to'].blank?

        to = date_arg(args, 'to', Date.current)
        from = date_arg(args, 'from', to - 365)
        raise ToolError.new('to must be on or after from.', kind: 'invalid_arguments') if to < from

        from.in_time_zone.beginning_of_day..to.in_time_zone.end_of_day
      end

      def like(scope, columns)
        return scope unless @query

        term = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
        scope.where(columns.map { |column| "LOWER(#{column}) LIKE :q" }.join(' OR '), q: term)
      end

      def dated(scope, column) = @range ? scope.where(column => @range) : scope

      def clip(text, length) = text.present? ? text.to_s.squish.truncate(length) : nil

      def offer_state(offer)
        return 'scheduled' if offer.starts_at > @now

        offer.ends_at >= @now ? 'active' : 'ended'
      end

      def discount_input(discount)
        discount.input
      rescue JSON::ParserError, TypeError
        nil
      end

      def benefit(input, currency)
        value = input&.dig('customerGets', 'value')
        return unless value

        if value['percentage']
          "#{(BigDecimal(value['percentage'].to_s) * 100).round(2).to_s('F').delete_suffix('.0')}% off"
        elsif value.dig('discountAmount', 'amount')
          "#{value.dig('discountAmount', 'amount')} #{currency} off"
        end
      rescue ArgumentError
        nil
      end

      def gift_totals(scope)
        totals = Hash.new { |hash, key| hash[key] = { gifts: 0, units: 0, product_cost_cents: 0, shipping_cost_cents: 0, gifts_missing_cost: 0 } }
        scope.includes(:items).find_each do |gift|
          row = totals[gift.currency]
          row[:gifts] += 1
          row[:units] += gift.items.to_a.sum(&:quantity)
          product = gift.estimated_product_cents
          product ? row[:product_cost_cents] += product : row[:gifts_missing_cost] += 1
          row[:shipping_cost_cents] += gift.shipping_cost_cents.to_i
        end
        totals.map do |currency, row|
          { currency: currency, **row, product_cost_dollars: money(row[:product_cost_cents]), shipping_cost_dollars: money(row[:shipping_cost_cents]) }
        end
      end

      def user_names(ids)
        User.unscoped.where(id: ids.compact.uniq).to_h { |user| [user.id, user_name(user)] }
      end

      def user_name(user) = user && (user.name.presence || "User #{user.id}")

      def subject_labels(events)
        events.group_by(&:subject_type).each_with_object({}) do |(type, group), labels|
          ids = group.map(&:subject_id).uniq
          found = case type
          when 'Marketing::Influencer' then Marketing::Influencer.where(id: ids).pluck(:id, :name)
          when 'Marketing::Engagement' then Marketing::Engagement.where(id: ids).pluck(:id, :title)
          when 'Marketing::Offer' then Marketing::Offer.where(id: ids).pluck(:id, :code)
          when 'Marketing::ShopifyDiscount' then Marketing::ShopifyDiscount.joins(:offer).where(id: ids).pluck(:id, 'marketing_offers.code')
          when 'Marketing::ProductGift'
            Marketing::ProductGift.joins(engagement: :influencer).where(id: ids).pluck(:id, 'marketing_influencers.name').map { |id, name| [id, "gift for #{name}"] }
          else []
          end
          found.each { |id, label| labels[[type, id]] = label }
        end
      end

      def summary(kind, status, counts, rows, meta, totals, enabled)
        count_text = counts.map { |key, value| "#{value} #{key.tr('_', ' ')}" }.join(', ')
        head = "#{kind.capitalize}: #{count_text.presence || 'none'}"
        head += " (#{DATE_FIELDS[kind]} #{@range.begin.to_date.iso8601} to #{@range.end.to_date.iso8601})" if @range
        head += '.'
        totals&.each do |row|
          head += " Gifts #{row[:currency]}: #{row[:units]} units, product cost #{row[:product_cost_dollars]}, shipping #{row[:shipping_cost_dollars]}" \
                  "#{" (#{row[:gifts_missing_cost]} without unit cost)" if row[:gifts_missing_cost].positive?}."
        end
        head += ' Usage counts are not stored in Rupert.' if kind == 'discounts'
        head += ' Marketing is turned off in this workspace.' unless enabled
        shown = rows.first(8).map { |row| row_label(kind, row) }
        "#{head} Showing #{rows.size}#{" #{status.tr('_', ' ')}" if status}#{' (more available)' if meta[:has_more]}" +
          (shown.any? ? ': ' + shown.join('; ') : '.')
      end

      def row_label(kind, row)
        case kind
        when 'campaigns' then "#{row[:name]} (#{row[:offers]} offers, #{row[:engagements]} collaborations)"
        when 'communities' then "#{row[:name]}#{' (rules need check)' unless row[:rules_current]}"
        when 'offers' then "#{row[:code]} #{row[:state]} until #{row[:ends_at]&.first(10)}"
        when 'discounts' then "#{row[:code]} #{row[:status]}#{" #{row[:benefit]}" if row[:benefit]}"
        when 'reviews' then "#{row[:thread].to_s.truncate(50)} (#{row[:status].tr('_', ' ')})"
        when 'influencers' then "#{row[:name]} (#{row[:stage]}#{', follow-up due' if row[:follow_up_due]})"
        when 'engagements' then "#{row[:title]} with #{row[:influencer]} (#{row[:status]})"
        when 'gifts' then "#{row[:influencer]}: #{row[:units]} units (#{row[:status]})"
        when 'events' then "#{row[:at]&.first(10)} #{row[:by]} #{row[:action].tr('_', ' ')} #{row[:subject]} #{row[:subject_name]}".squish
        end
      end
    end
  end
end
