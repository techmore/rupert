# frozen_string_literal: true

# Forgotten clock-outs: Rupert clock-ins and Square timecards still open after the
# workspace's limit (PayRules open_shift_limit_hours, 16 by default). They count no
# hours until fixed: a Rupert shift through a reviewed ClockCorrection (never an
# edit), a Square card in Square itself.
class OpenClockOuts
  Item = Struct.new(:kind, :record, :employee_id, :employee_name, :started_at, keyword_init: true) do
    def rupert? = kind == :rupert
  end

  attr_reader :at

  # Who may open Fix clock-out on someone else's shift, and who is told about one.
  def self.manager?(user)
    !!(user&.active? && (user.can?('timesheets.write') || user.can?('payroll.write')))
  end

  def initialize(at: Time.current)
    @at = at
  end

  def limit_hours
    ClockShift.stale_open_hours
  end

  def cutoff
    at - limit_hours.hours
  end

  def shifts(employee_ids: nil)
    scope = ClockShift.stale_open(at).includes(:employee).order(:started_at, :id)
    employee_ids ? scope.where(employee_id: employee_ids) : scope
  end

  def square_cards(employee_ids: nil)
    scope = SquareTimecard.where(import_status: 'open').where(started_at: ...cutoff).includes(:employee).order(:started_at, :id)
    employee_ids ? scope.where(employee_id: employee_ids) : scope
  end

  def items(employee_ids: nil)
    rupert = shifts(employee_ids: employee_ids).map do |shift|
      Item.new(kind: :rupert, record: shift, employee_id: shift.employee_id, employee_name: shift.employee&.name || shift.employee_name, started_at: shift.started_at)
    end
    square = square_cards(employee_ids: employee_ids).map do |card|
      Item.new(kind: :square, record: card, employee_id: card.employee_id, employee_name: card.employee&.name || 'Staff member not matched', started_at: card.started_at)
    end
    (rupert + square).sort_by(&:started_at)
  end

  # Tells every manager once per open shift (Notification dedupe_key), never the worker about themselves.
  def notify_managers!
    managers = User.where(tenant_id: Current.tenant_id).active.select { |user| self.class.manager?(user) }
    return 0 if managers.empty?

    helpers = ApplicationController.helpers
    routes = Rails.application.routes.url_helpers
    items.sum do |item|
      url = item.rupert? ? routes.fix_clock_out_time_clock_path(item.record) : routes.people_square_timesheet_path(item.record)
      where = item.rupert? ? 'Rupert time clock' : 'Square'
      managers.count do |manager|
        # Nobody is told about their own shift.
        next false if (item.rupert? && item.record.user_id == manager.id) || item.record.employee&.user_id == manager.id

        Notification.deliver(manager.id, kind: 'open_clock_out', actor: nil, url: url,
          dedupe_key: "open_clock_out:#{item.kind}:#{item.record.id}",
          title: "#{item.employee_name} never clocked out",
          body: "#{helpers.open_clock_out_label(item.started_at, at)} (#{where}, #{I18n.l(item.started_at, format: '%a %b %-d, %-I:%M %p')}). " \
                'These hours are not counted until the clock-out is fixed.')&.persisted?
      end
    end
  end
end
