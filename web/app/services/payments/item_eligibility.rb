# frozen_string_literal: true

module Payments
  # Can these items be charged on this payment processor? (F69, shared with F70.)
  #
  #   result = Payments::ItemEligibility.check(processor: 'authorize_net', items: lines)
  #   result.allowed?      # => false
  #   result.blocked       # => [{ item: {...}, reason: 'not on the Authorize.net approved list' }]
  #   result.message       # => cashier-ready text naming the items and what to do instead
  #   result.alternatives  # => ['cash', 'nmi'] (tenders where every item passes)
  #
  #   Payments::ItemEligibility.check!(processor:, items:)  # raises Blocked with #message
  #
  # processor: 'authorize_net', 'nmi', 'card_terminal' (a standalone processor
  # terminal, e.g. the A920 tender) or 'cash'.
  # items: hashes (string or symbol keys) or objects with sku, category, name/title,
  # variant_id and optionally custom (true for open-price or free-text items).
  #
  # Rules are callables `(processor:, item:) -> nil | reason`. The built-in rule is
  # the per-processor approved list (ProcessorCatalog). Other guardrails (F70: COA,
  # custom items, event subsets) append their own rule with `register_rule` rather
  # than run a parallel check, so every tender path enforces the same answer.
  class ItemEligibility
    PROCESSORS = (ProcessorCatalog::PROCESSORS.keys + ['cash']).freeze

    class Blocked < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.message)
      end
    end

    Item = Struct.new(:sku, :category, :name, :variant_id, :custom, keyword_init: true) do
      def label
        base = name.presence || (sku.present? ? "SKU #{sku}" : 'Item')
        sku.present? && name.present? ? "#{base} (SKU #{sku})" : base
      end
    end

    Result = Struct.new(:processor, :blocked, :alternatives, keyword_init: true) do
      def allowed? = blocked.empty?

      def blocked_summary = blocked.map { |row| row[:item].label }.to_sentence

      def message
        return nil if allowed?

        names = blocked.map { |row| "#{row[:item].label}: #{row[:reason]}" }
        tender = ItemEligibility.label(processor)
        text = +"#{tender} can't take #{blocked.size == 1 ? 'this item' : 'these items'}. #{names.join('; ')}."
        text << if alternatives.any?
          " Use #{alternatives.map { |key| ItemEligibility.label(key) }.to_sentence(two_words_connector: ' or ', last_word_connector: ', or ')} instead, or remove #{blocked.size == 1 ? 'it' : 'them'} from the sale."
        else
          " Remove #{blocked.size == 1 ? 'it' : 'them'} from the sale."
        end
        text
      end
    end

    # Approved-list rule. A processor with no catalog, or one not enforced, keeps
    # today's behaviour (everything allowed); cash is never restricted here.
    class ApprovedListRule
      def initialize
        @catalogs = {}
      end

      def call(processor:, item:)
        return nil if processor == 'cash'

        catalog = @catalogs.fetch(processor) { @catalogs[processor] = ProcessorCatalog.find_by(processor: processor) }
        return nil unless catalog&.enforced

        reason_for(catalog, item)
      end

      def reason_for(catalog, item)
        return nil unless catalog.enforced

        sets = catalog.lookup
        sku = item.sku.present? ? ProcessorCatalogEntry.normalize('sku', item.sku) : nil
        category = item.category.present? ? ProcessorCatalogEntry.normalize('category', item.category) : nil
        return "excluded from the #{catalog.label} approved list" if sku && sets['excluded_sku'].include?(sku)
        return nil if sku && sets['sku'].include?(sku)
        return nil if category && sets['category'].include?(category)
        return "has no SKU or category, so #{catalog.label} approval can't be confirmed" if sku.nil? && category.nil?

        "not on the #{catalog.label} approved list"
      end
    end

    class << self
      def rules
        @rules ||= [ApprovedListRule]
      end

      # Add a rule class (instantiated per check, so it may cache per check) or
      # any object responding to call(processor:, item:).
      def register_rule(rule)
        rules << rule unless rules.include?(rule)
        rule
      end

      def check(processor:, items:)
        processor = processor.to_s
        raise ArgumentError, "Unknown payment processor #{processor.inspect}" unless PROCESSORS.include?(processor)

        normalized = Array(items).map { |item| normalize_item(item) }
        live_rules = rules.map { |rule| rule.is_a?(Class) ? rule.new : rule }
        evaluate = lambda do |key|
          normalized.filter_map do |item|
            reason = live_rules.lazy.filter_map { |rule| rule.call(processor: key, item: item) }.first
            { item: item, reason: reason } if reason
          end
        end
        blocked = evaluate.call(processor)
        alternatives = blocked.empty? ? [] : (alternatives_for(processor) & PROCESSORS).select { |key| evaluate.call(key).empty? }
        Result.new(processor: processor, blocked: blocked, alternatives: alternatives)
      end

      def check!(processor:, items:)
        result = check(processor: processor, items: items)
        raise Blocked, result unless result.allowed?

        result
      end

      # The processor that a POS checkout tender charges through.
      def processor_for_tender(tender, gateway_provider = nil)
        case tender.to_s
        when 'cash' then 'cash'
        when PosCheckout::TERMINAL_CARD then 'card_terminal'
        else gateway_provider.presence || 'authorize_net'
        end
      end

      def label(processor)
        processor.to_s == 'cash' ? 'Cash' : "Card (#{ProcessorCatalog.label_for(processor)})"
      end

      private

      # Route only to cash or to a card processor whose enforced list explicitly
      # covers the items. Never suggest an unrestricted processor for an item
      # another processor refused: that is how a merchant ends up miscoding a
      # product and losing card acceptance (MATCH listing).
      def alternatives_for(processor)
        ['cash'] + ProcessorCatalog.where(enforced: true).where.not(processor: processor).order(:processor).pluck(:processor) - [processor]
      end

      def normalize_item(item)
        return item if item.is_a?(Item)

        value = lambda do |*keys|
          keys.each do |key|
            found = if item.is_a?(Hash)
              item[key.to_s] || item[key.to_sym]
            elsif item.respond_to?(key)
              item.public_send(key)
            end
            return found if found.present? || found == true
          end
          nil
        end
        Item.new(sku: value.call(:sku)&.to_s, category: value.call(:category)&.to_s,
          name: (value.call(:name) || value.call(:title))&.to_s, variant_id: value.call(:variant_id)&.to_s,
          custom: value.call(:custom) == true)
      end
    end
  end
end
