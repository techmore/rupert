# frozen_string_literal: true

# Settles a Square timecard that was edited or removed in Square after import.
#
# Accept takes Square's latest version: the card's counted days are rebuilt from it
# (or removed, when Square deleted the card). Keep original leaves the counted hours
# and remembers the Square version so the next import does not flag it again.
#
# A submitted, approved or paid period is never changed: accepting there records a
# `held` decision, leaves the hours alone and flags each locked timesheet, so the
# manager reopens it first. Every decision is an append-only SquareTimecardReview.
class SquareTimecardReviewer
  class Error < StandardError; end

  Lock = Struct.new(:label, :timesheet, keyword_init: true)

  def self.allowed?(user)
    !!(user&.active? && user.can?('timesheets.read') && user.can?('timesheets.write') && (user.super_admin? || user.tenant_id == Current.tenant_id))
  end

  def self.queue
    SquareTimecard.awaiting_review.includes(:employee, :days)
  end

  # Every Square version seen and every decision, oldest first, for the timecard's history.
  def self.history(card)
    importer = SquareTimecardImport.new
    versions = card.versions.includes(:employee).chronological.map do |version|
      parsed = version.kind == 'seen' ? importer.normalize(version.row) : nil
      attrs = parsed ? parsed[:attributes] : {}
      { at: version.seen_at, kind: version.kind, who: 'Square', employee: version.employee, source_version: version.source_version,
        source_updated_at: version.source_updated_at, state: parsed&.dig(:state), started_at: attrs[:started_at], ended_at: attrs[:ended_at],
        seconds: attrs[:payable_seconds], timezone: attrs[:timezone] }
    end
    reviews = card.reviews.includes(:reviewer).order(:created_at, :id).map do |review|
      { at: review.created_at, kind: review.decision, who: review.reviewer&.display_name || 'Former account', reason: review.reason, held_by: review.held_by,
        counted_seconds: review.counted_payable_seconds, latest_seconds: review.latest_payable_seconds }
    end
    (versions + reviews).sort_by { |event| [event[:at], event[:who] == 'Square' ? 0 : 1] }
  end

  attr_reader :card

  def initialize(card, reviewer: Current.user)
    @card, @reviewer = card, reviewer
  end

  # Counted and latest versions side by side, plus what (if anything) stands in the way of accepting.
  def comparison
    @comparison ||= begin
      latest = latest_row
      parsed = latest && importer.normalize(latest)
      worker = latest && EmployeeSourceIdentity.find_by(source: 'square', external_id: latest['team_member_id'])&.employee
      attrs = parsed ? parsed[:attributes] : {}
      { counted: { started_at: card.started_at, ended_at: card.ended_at, seconds: card.payable_seconds.to_i, timezone: card.timezone, employee: card.employee },
        latest: { removed: latest.nil?, state: parsed&.dig(:state), started_at: attrs[:started_at], ended_at: attrs[:ended_at],
                  seconds: attrs[:payable_seconds].to_i, timezone: attrs[:timezone], employee: worker, days: parsed ? parsed[:days] : [], digest: parsed&.dig(:digest), row: latest },
        seen_key: seen_key(parsed&.dig(:digest), worker&.id) }.tap do |result|
        result[:blocker] = blocker(result[:latest])
        result[:locks] = locks(result[:latest])
      end
    end
  end

  def delta_seconds
    comparison[:latest][:seconds] - comparison[:counted][:seconds]
  end

  def accept!(reason:, seen_key:)
    decide(reason, seen_key) do |view|
      raise Error, view[:blocker] if view[:blocker]

      if view[:locks].any?
        held = view[:locks].map(&:label).to_sentence
        view[:locks].filter_map(&:timesheet).each do |sheet|
          sheet.events.create!(user: @reviewer, action: 'square_edit_held', details: { square_timecard_id: card.id, external_id: card.external_id, reason: reason })
        end
        card.update!(issue: "Square edit waiting: #{held} is locked. Reopen it, then accept again; original hours still count.")
        next ['held', held]
      end

      latest = view[:latest]
      card.days.each(&:destroy!)
      if latest[:removed]
        card.update!(import_status: 'removed', issue: 'Removed in Square; the removal was accepted, so this card counts no hours.',
          payable_seconds: 0, unpaid_break_seconds: 0, original_digest: nil, kept_source_key: nil)
      else
        parsed = importer.normalize(latest[:row])
        card.update!(parsed[:attributes].merge(employee: latest[:employee], team_member_id: latest[:row]['team_member_id'], source_payload: JSON.generate(latest[:row]),
          original_digest: parsed[:digest], import_status: 'imported', issue: nil, kept_source_key: nil))
        parsed[:days].each { |day| card.days.create!(day) }
      end
      ['accepted', nil]
    end
  end

  def keep!(reason:, seen_key:)
    decide(reason, seen_key) do |view|
      latest = view[:latest]
      key = latest[:removed] ? 'missing' : SquareTimecardImport.kept_key(latest[:digest], latest[:employee]&.id)
      card.update!(import_status: card.original_digest.nil? ? 'removed' : 'imported', issue: nil, kept_source_key: key)
      ['kept', nil]
    end
  end

  private

  def importer
    @importer ||= SquareTimecardImport.new(actor: @reviewer)
  end

  def latest_row
    return nil if card.import_status == 'missing'

    row = JSON.parse(card.latest_payload.to_s)
    row.is_a?(Hash) ? row : {}
  rescue JSON::ParserError
    {}
  end

  # What the reviewer was looking at; a newer Square read in between makes the decision stale.
  def seen_key(digest, worker_id)
    [card.import_status, digest || 'missing', worker_id].join(':')
  end

  def blocker(latest)
    return nil if latest[:removed]
    return 'Square’s latest version is still open. Wait for it to close, or keep the original hours.' if latest[:state] == 'open'
    return 'Square’s latest version has invalid dates or breaks. Fix it in Square, or keep the original hours.' unless latest[:state] == 'imported'
    return 'Square’s latest version is not matched to a staff member. Link the Square identity first, or keep the original hours.' unless latest[:employee]
    if latest[:seconds].positive? && importer.overlaps_existing?(latest[:employee], latest[:started_at], latest[:ended_at], except_card: card)
      return 'Square’s latest times overlap other counted work for this person. Fix the overlap first, or keep the original hours.'
    end

    nil
  end

  # Submitted, approved or paid periods the change would touch, for the old and new staff member.
  def locks(latest)
    dates = card.days.map(&:worked_on) + latest[:days].map { |day| day[:worked_on] }
    dates << card.started_at.in_time_zone(card.timezone.presence || Time.zone).to_date if dates.empty? && card.started_at
    employees = [card.employee_id, latest[:employee]&.id].compact.uniq
    return [] if dates.empty? || employees.empty?

    first, last = dates.minmax
    covers = ->(record) { dates.any? { |day| (record.period_start..record.period_end).cover?(day) } }
    sheets = People::Timesheet.where(employee_id: employees).where('period_start <= ? AND period_end >= ?', last, first).includes(:employee).select(&covers)
    found = sheets.filter_map do |sheet|
      state = sheet.payroll_locked? ? 'paid' : sheet.status
      next unless %w[submitted approved paid].include?(state)

      Lock.new(label: "#{sheet.employee.name}’s #{sheet.period_label} timesheet (#{state})", timesheet: sheet)
    end
    runs = People::PayRun.where(status: %w[finalized paid]).where('period_start <= ? AND period_end >= ?', last, first)
      .where(id: People::Payslip.where(employee_id: employees).select(:pay_run_id)).select(&covers)
    found + runs.map { |run| Lock.new(label: "the #{run.name} pay run (#{run.status})") }
  end

  def decide(reason, seen_key)
    reason = reason.to_s.strip
    raise Error, 'Say why, in a few words.' if reason.blank?
    raise Error, 'Keep the reason under 1,000 characters.' if reason.length > 1000

    SquareTimecard.transaction do
      # Same writer lock as the import, so a Square read cannot land halfway through a decision.
      raise ActiveRecord::RecordNotFound unless Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at') == 1

      @reviewer = User.find_by(id: @reviewer&.id, active: true)
      raise Pundit::NotAuthorizedError unless self.class.allowed?(@reviewer)

      card.reload
      @comparison = nil
      raise Error, 'This timecard no longer needs review.' unless card.imported_at && SquareTimecard::REVIEW_STATUSES.include?(card.import_status)

      view = comparison
      raise Error, 'Square sent a newer version while you were looking. Review it again.' unless view[:seen_key] == seen_key
      if [card.employee, view[:latest][:employee]].compact.any? { |worker| worker.user_id == @reviewer.id }
        raise Error, 'Another manager must review a change to your own hours.'
      end

      before = { status: card.import_status, digest: card.original_digest, employee_id: card.employee_id }
      SquareTimecardVersion.baseline!(card)
      latest = view[:latest]
      if latest[:removed]
        SquareTimecardVersion.record!(card, kind: 'missing', seen_at: card.updated_at)
      else
        SquareTimecardVersion.record!(card, kind: 'seen', seen_at: card.last_seen_at, row: latest[:row], digest: latest[:digest], employee_id: latest[:employee]&.id)
      end
      decision, held_by = yield(view)
      review = card.reviews.create!(reviewer: @reviewer, decision: decision, reason: reason, held_by: held_by,
        status_before: before[:status], counted_digest: before[:digest], latest_digest: latest[:digest],
        employee_id_before: before[:employee_id], employee_id_after: latest[:employee]&.id,
        counted_started_at: view[:counted][:started_at], counted_ended_at: view[:counted][:ended_at], counted_payable_seconds: view[:counted][:seconds],
        latest_started_at: latest[:started_at], latest_ended_at: latest[:ended_at], latest_payable_seconds: latest[:removed] ? 0 : latest[:seconds])
      ActivityLogger.log("square_timecard_#{decision}", subject: card, actor: @reviewer,
        details: { external_id: card.external_id, counted_seconds: view[:counted][:seconds], latest_seconds: latest[:seconds], held_by: held_by }.to_json)
      review
    end
  end
end
