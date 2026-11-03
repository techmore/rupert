# frozen_string_literal: true

# Helpers for the public policy pages (privacy, terms, refunds, security, integrations, support).
module PublicPagesHelper
  # A fact the owner still has to supply. It renders as a visible, highlighted bracket so an
  # unfinished page can never pass for a finished one.
  def owner_placeholder(what)
    tag.mark("[Owner to add: #{what}]", class: 'owner-placeholder', data: { owner_placeholder: what })
  end

  # A company fact from PublicPagesController.company, or its placeholder when it is not set.
  def company_fact(key, what)
    PublicPagesController.company[key].presence || owner_placeholder(what)
  end

  def company_operator_name
    PublicPagesController::OPERATOR_NAME
  end

  def company_legal_name
    company_fact(:legal_name, "registered legal entity name and state, if different from #{company_operator_name}")
  end
end
