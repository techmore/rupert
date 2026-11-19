# frozen_string_literal: true

# Who to call when payments break, kept as workspace configuration (not in lesson text) so the
# owner can change a number without editing a course. Stored in the encrypted Setting table.
# Defaults are the companies' public support lines from docs/ops/payment-basics.md; an account
# representative's direct line belongs here once the owner enters it.
class Lms::SupportContacts
  KEY = 'lms.support_contacts'
  Contact = Struct.new(:key, :label, :role, :phone, :hours, :notes, keyword_init: true) do
    def blank? = phone.blank? && notes.blank?
  end

  DEFAULTS = [
    { key: 'valmar', label: 'Valmar Merchant Services', role: 'Merchant account, statements, chargebacks, terminal support',
      phone: '1-866-825-6271', hours: '', notes: 'Public company line. Ask for our account representative.' },
    { key: 'dejavoo', label: 'Dejavoo terminal (P18)', role: 'Terminal will not connect, batch will not close, tip adjust problems',
      phone: '', hours: '', notes: 'Call Valmar first: they support the terminal they shipped.' },
    { key: 'authorize_net', label: 'Authorize.net', role: 'Online checkout gateway, settlement reports, refunds of online orders',
      phone: '1-877-447-3938', hours: '', notes: 'Existing-account support. Have the Gateway ID ready, never a card number.' },
    { key: 'owner', label: 'Owner / manager on duty', role: 'Anything involving money that does not match, a dispute letter, or a refund over the limit',
      phone: '', hours: '', notes: '' }
  ].freeze

  def self.for_tenant(tenant_id = Current.tenant_id)
    saved = parse(Setting.for_tenant(KEY, tenant_id)&.value)
    DEFAULTS.map do |default|
      override = saved[default[:key]] || {}
      Contact.new(**default.merge(override.slice('phone', 'hours', 'notes').transform_keys(&:to_sym)))
    end
  end

  def self.save!(params, tenant_id = Current.tenant_id)
    clean = DEFAULTS.each_with_object({}) do |default, out|
      given = params[default[:key]] || {}
      out[default[:key]] = {
        'phone' => given['phone'].to_s.strip.first(40), 'hours' => given['hours'].to_s.strip.first(80), 'notes' => given['notes'].to_s.strip.first(300)
      }
    end
    Setting.find_or_create_for(KEY, tenant_id) { |row| row.value = JSON.generate(clean) }
  end

  def self.parse(json)
    parsed = JSON.parse(json.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end
end
