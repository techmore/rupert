# frozen_string_literal: true

# A meal or rest break inside one clock shift. Rest breaks are paid (default); meal breaks are
# unpaid unless the location's time rules say otherwise. An open break (no ended_at) is the one
# the worker is on right now; a shift has at most one open break (unique partial index).
class ClockBreak < ApplicationRecord
  include TenantScoped
  include LockedPayPeriodGuard

  guards_pay_period { [(new_record? || started_at_changed?) ? started_at : nil, ended_at_changed? ? ended_at : nil] }

  KINDS = %w[rest meal].freeze
  LABELS = { 'rest' => 'Break', 'meal' => 'Meal' }.freeze

  belongs_to :clock_shift

  validates :kind, inclusion: { in: KINDS }
  validates :started_at, presence: true
  validate :inside_shift

  scope :open, -> { where(ended_at: nil) }
  scope :chronological, -> { order(:started_at, :id) }

  def open? = ended_at.nil?
  def label = LABELS.fetch(kind, kind)

  def minutes(at: Time.current)
    (([ended_at || at, started_at].max - started_at) / 60.0).round
  end

  def seconds(at: Time.current)
    [(ended_at || at) - started_at, 0].max
  end

  private

  def inside_shift
    return if started_at.nil? || clock_shift.nil?

    errors.add(:started_at, 'must be after clock-in') if started_at < clock_shift.started_at
    errors.add(:ended_at, 'must be after the break started') if ended_at && ended_at <= started_at
    errors.add(:ended_at, 'cannot be after clock-out') if ended_at && clock_shift.ended_at && ended_at > clock_shift.ended_at
    errors.add(:started_at, 'cannot be after clock-out') if clock_shift.ended_at && started_at >= clock_shift.ended_at
  end
end
