# frozen_string_literal: true

# One pay period as payroll sees it: open while hours, tips and corrections can still change, locked
# once a payroll operator closes it, exported once the payroll file has been produced. A locked
# period refuses new or changed hours and tip allocations inside its dates; anything that arrives
# later (a card batch that settles after the lock, an approved correction) is carried into the next
# open period as an adjustment, so the exported file never silently changes.
class PayPeriod < ApplicationRecord
  include TenantScoped

  STATUSES = %w[open locked exported].freeze

  belongs_to :locked_by, class_name: 'User', optional: true
  belongs_to :exported_by, class_name: 'User', optional: true
  has_many :adjustments, class_name: 'PayPeriodAdjustment', dependent: :restrict_with_exception

  validates :starts_on, :ends_on, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :ordered

  scope :chronological, -> { order(:starts_on) }

  # The period holding `date`, created open from the pay rules when it does not exist yet.
  def self.for_date(date, rules: PayRules.current)
    starts_on, ends_on = rules.period_range(date.to_date)
    find_by(starts_on: starts_on) || create!(starts_on: starts_on, ends_on: ends_on)
  rescue ActiveRecord::RecordNotUnique
    find_by!(starts_on: starts_on)
  end

  # Whether a change dated `date` may still be recorded in its period: false once that period is locked.
  def self.open_for?(date)
    period = find_by('starts_on <= ? AND ends_on >= ?', date.to_date, date.to_date)
    period.nil? || period.open?
  end

  # The first open period on or after `date` (for carried adjustments).
  def self.next_open_from(date, rules: PayRules.current)
    cursor = date.to_date
    20.times do
      period = for_date(cursor, rules: rules)
      return period if period.open?

      cursor = period.ends_on + 1
    end
    nil
  end

  def open? = status == 'open'
  def locked? = status != 'open'
  def label = "#{starts_on.strftime('%b %-d')} – #{ends_on.strftime('%b %-d, %Y')}"
  def range = starts_on..ends_on

  def lock!(by:, totals: nil, note: nil)
    raise ArgumentError, 'already locked' if locked?

    update!(status: 'locked', locked_at: Time.current, locked_by: by, totals_json: totals&.to_json, note: note.presence || self.note)
  end

  def mark_exported!(by:, sha256:)
    update!(status: 'exported', exported_at: Time.current, exported_by: by, export_sha256: sha256)
  end

  # Reopening is allowed only by a payroll writer and is logged by the caller; the export digest stays as evidence.
  def reopen!
    update!(status: 'open', locked_at: nil, locked_by: nil)
  end

  def totals
    totals_json.present? ? JSON.parse(totals_json) : {}
  rescue JSON::ParserError
    {}
  end

  private

  def ordered
    errors.add(:ends_on, 'must be after the start') if starts_on && ends_on && ends_on < starts_on
  end
end
