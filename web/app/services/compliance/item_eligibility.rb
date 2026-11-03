# frozen_string_literal: true

module Compliance
  # The one answer to "may these items be rung up with this tender?" (F70).
  # The register, the event register and payment paths (F69 processor
  # allow-lists) all ask here, so a rule is written once.
  #
  #   lines  = Compliance::ItemEligibility.lines_for_ctrax(location:, variant_ids: %w[101 102])
  #   result = Compliance::ItemEligibility.check(lines, tender: 'card', processor: allow_list)
  #   result.allowed?      # => false when any issue blocks the sale
  #   result.overridable?  # => true when every blocking issue accepts a manager PIN override
  #   result.issues        # => [Issue(code:, severity:, overridable:, item_key:, item_name:, message:)]
  #
  # Inputs
  # - lines: Line values (key, name, catalog_item). catalog_item is the store's
  #   ComplianceCatalogItem, or nil when the product is not on the approved list.
  # - tender: any tender string. Only NON_CARD_TENDERS count as cash; everything
  #   else (card, card_a920, card_terminal, online card, a tender added later) is
  #   checked against the card rules, so an unknown tender fails safe.
  # - processor: optional allow-list for the card processor that will take the
  #   payment. Any object with #name and #permits?(catalog_item) works (see
  #   CategoryAllowList). It is consulted only for card tenders.
  # - policy: the store's CompliancePolicy (COA age limit). Defaults to 365 days.
  # - on: the business date the sale happens (COA currency, federal THC rule).
  #
  # It decides nothing about legality: it enforces the owner's approved catalog.
  class ItemEligibility
    NON_CARD_TENDERS = %w[cash].freeze
    # P.L. 119-37 §781 as delayed by H.R. 6500: finished hemp-derived products are
    # limited to 0.4 mg total THC per container from this date.
    FEDERAL_THC_RULE_DATE = Date.new(2026, 12, 11)
    FEDERAL_THC_LIMIT_MG = BigDecimal('0.4')

    Line = Data.define(:key, :name, :catalog_item)

    Issue = Data.define(:code, :severity, :overridable, :item_key, :item_name, :message) do
      def block? = severity == :block
      def to_h = { code: code, severity: severity.to_s, overridable: overridable, item_key: item_key, item_name: item_name, message: message }
    end

    class Result
      attr_reader :issues, :tender_kind

      def initialize(issues, tender_kind)
        @issues = issues.freeze
        @tender_kind = tender_kind
      end

      def allowed? = blocking.empty?
      def blocking = issues.select(&:block?)
      def warnings = issues.reject(&:block?)
      def overridable? = blocking.any? && blocking.all?(&:overridable)
      def codes = issues.map(&:code).uniq
      def for(key) = issues.select { |issue| issue.item_key == key }
      def as_json(*) = { allowed: allowed?, overridable: overridable?, tender_kind: tender_kind.to_s, issues: issues.map(&:to_h) }
    end

    # A processor allow-list by approved category name (case-insensitive).
    CategoryAllowList = Data.define(:name, :category_names) do
      def permits?(catalog_item) = category_names.map { |n| n.to_s.downcase }.include?(catalog_item.category_name.to_s.downcase)
    end

    def self.tender_kind(tender) = NON_CARD_TENDERS.include?(tender.to_s) ? :cash : :card

    # Lines for native C-Trax variants of one store, with their catalog items loaded.
    def self.lines_for_ctrax(location:, variant_ids:, names: {})
      items = ComplianceCatalogItem.includes(:compliance_category, :certificates_of_analysis)
        .where(location_id: location.id, source: 'ctrax', source_variant_id: variant_ids.map(&:to_s)).index_by(&:source_variant_id)
      variant_ids.map do |id|
        item = items[id.to_s]
        Line.new(key: id.to_s, name: item&.compliant_name || names[id.to_s] || "Item #{id}", catalog_item: item)
      end
    end

    def self.check(lines, tender:, processor: nil, policy: nil, on: Date.current)
      new(tender: tender, processor: processor, policy: policy, on: on).check(lines)
    end

    def initialize(tender:, processor: nil, policy: nil, on: Date.current)
      @kind = self.class.tender_kind(tender)
      @processor = processor
      @max_age = policy&.coa_max_age_days || CompliancePolicy::DEFAULT_COA_MAX_AGE_DAYS
      @on = on
    end

    def check(lines)
      Result.new(lines.flat_map { |line| line_issues(line) }, @kind)
    end

    private

    def line_issues(line)
      item = line.catalog_item
      return [issue(line, :not_approved, :block, false, 'is not on the approved catalog. Ask the owner to approve it first.')] unless item
      return [issue(line, :suspended, :block, false, 'is suspended on the approved catalog.')] unless item.approved?

      category = item.compliance_category
      return [issue(line, :category_prohibited, :block, false, "is in a prohibited category (#{category.name}).")] if category.prohibited

      issues = []
      issues.concat(thc_issues(line, item))
      if @kind == :cash
        issues << issue(line, :cash_ineligible, :block, false, 'is not approved for cash sales.') unless item.cash_eligible
      else
        unless item.card_eligible && category.card_eligible
          issues << issue(line, :card_ineligible, :block, true, 'is not approved for card sales. Take cash, or a manager can override with a reason.')
        end
        if @processor && !@processor.permits?(item)
          issues << issue(line, :processor_not_allowed, :block, false, "is not on #{@processor.name}’s approved product list.")
        end
      end
      issues.concat(coa_issues(line, item))
      issues
    end

    def coa_issues(line, item)
      return [] unless item.coa_required
      return [] if item.current_coa(on: @on, max_age_days: @max_age)

      latest = item.latest_coa
      code, text = if latest
        [:coa_expired, "has no current COA (the latest stopped being current #{latest.current_until(max_age_days: @max_age).strftime('%b %-d, %Y')})."]
      else
        [:coa_missing, 'has no COA on file.']
      end
      # Cash still sells with a warning; card needs a current COA or an override.
      @kind == :card ? [issue(line, code, :block, true, text)] : [issue(line, code, :warn, false, text)]
    end

    def thc_issues(line, item)
      thc = item.thc_mg_per_container
      if @on >= FEDERAL_THC_RULE_DATE
        return [issue(line, :thc_unknown, :warn, false, 'has no THC per container recorded for the federal hemp limit.')] if thc.nil?
        return [issue(line, :thc_over_federal_limit, :block, false, "has #{thc.to_s('F')} mg THC per container, over the federal #{FEDERAL_THC_LIMIT_MG.to_s('F')} mg limit.")] if thc > FEDERAL_THC_LIMIT_MG
      elsif thc && thc > FEDERAL_THC_LIMIT_MG
        return [issue(line, :thc_over_federal_limit_soon, :warn, false, "is over the federal #{FEDERAL_THC_LIMIT_MG.to_s('F')} mg THC per container limit that starts #{FEDERAL_THC_RULE_DATE.strftime('%b %-d, %Y')}.")]
      end
      []
    end

    def issue(line, code, severity, overridable, text)
      Issue.new(code: code, severity: severity, overridable: overridable, item_key: line.key, item_name: line.name, message: "#{line.name} #{text}")
    end
  end
end
