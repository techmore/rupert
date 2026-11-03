# frozen_string_literal: true

require 'rqrcode'

# Compliance views (F70): issue pills, COA status and receipt QR codes.
module ComplianceHelper
  ISSUE_LABELS = {
    'not_approved' => 'Not approved', 'suspended' => 'Suspended', 'category_prohibited' => 'Prohibited category',
    'cash_ineligible' => 'No cash', 'card_ineligible' => 'Card not approved', 'processor_not_allowed' => 'Processor does not allow',
    'coa_missing' => 'No COA', 'coa_expired' => 'COA not current', 'thc_unknown' => 'THC per container unknown',
    'thc_over_federal_limit' => 'Over federal THC limit', 'thc_over_federal_limit_soon' => 'Over THC limit from Dec 11',
    'id_not_checked' => 'ID not checked'
  }.freeze

  ACTION_LABELS = {
    'category_saved' => 'Category saved', 'catalog_item_approved' => 'Item approved', 'catalog_item_edited' => 'Item edited',
    'catalog_item_suspended' => 'Item suspended', 'catalog_item_reinstated' => 'Item reinstated', 'coa_added' => 'COA added',
    'coa_withdrawn' => 'COA withdrawn', 'policy_changed' => 'Register rules changed', 'override_pin_set' => 'Override PIN set',
    'sale_blocked' => 'Sale blocked', 'override_granted' => 'Override approved', 'override_refused' => 'Override refused',
    'event_created' => 'Event added', 'event_edited' => 'Event edited', 'event_opened' => 'Event opened',
    'event_item_pulled' => 'Event item pulled', 'event_closed' => 'Event closed', 'event_sale' => 'Event sale',
    'event_sale_flagged' => 'Event sale flagged'
  }.freeze

  def compliance_issue_label(code) = ISSUE_LABELS.fetch(code.to_s, code.to_s.humanize)
  def compliance_action_label(action) = ACTION_LABELS.fetch(action.to_s, action.to_s.humanize)

  def compliance_action_pill(action)
    tone = case action.to_s
           when 'sale_blocked', 'override_refused', 'event_sale_flagged' then 'pill-rose'
           when 'override_granted', 'event_item_pulled', 'catalog_item_suspended', 'coa_withdrawn' then 'pill-clay'
           else 'pill-olive'
           end
    tag.span(compliance_action_label(action), class: tone)
  end

  # Current / Expiring / Not current / Missing, for one catalog item.
  def coa_status_pill(item, policy)
    return tag.span('Not required', class: 'pill-taupe') unless item.coa_required

    coa = item.current_coa(max_age_days: policy.coa_max_age_days)
    return tag.span(item.latest_coa ? 'Not current' : 'Missing', class: 'pill-rose') unless coa

    until_day = coa.current_until(max_age_days: policy.coa_max_age_days)
    if until_day < 30.days.from_now.to_date
      tag.span("Expires #{until_day.strftime('%b %-d')}", class: 'pill-clay')
    else
      tag.span('Current', class: 'pill-fern')
    end
  end

  # An inline SVG QR code for an https COA link: black on a white tile in
  # every theme, so phone cameras and printers read it.
  def coa_qr_svg(url, label:)
    return if url.blank?

    svg = RQRCode::QRCode.new(url, level: :m).as_svg(standalone: true, use_path: true, viewbox: true, shape_rendering: 'crispEdges')
      .sub(/\A<\?xml[^>]*\?>/, '')
    tag.figure(class: 'coa-qr') do
      # SVG generated here from the stored https link; no user markup reaches it.
      safe_join([tag.div(svg.html_safe, class: 'coa-qr-code', role: 'img', 'aria-label': "QR code: #{label}"),
        tag.figcaption(label, class: 'coa-qr-label')])
    end
  end
end
