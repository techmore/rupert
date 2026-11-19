# frozen_string_literal: true

module LmsHelper
  # Done / In progress / Not started / Overdue as the one pill per status.
  def lms_status_pill(status)
    tone = { 'completed' => 'fern', 'in_progress' => 'clay', 'overdue' => 'rose', 'assigned' => 'taupe', 'not_assigned' => 'taupe' }.fetch(status, 'taupe')
    label = t("lms.status.#{status}", default: status.to_s.humanize)
    tag.span(label, class: "pill-#{tone}")
  end

  # A progress ring: SVG circle with the figure inside; the label carries the meaning for a screen reader.
  def lms_progress_ring(percent, label:, size: :md)
    percent = percent.to_i.clamp(0, 100)
    radius = 15.5
    circumference = (2 * Math::PI * radius).round(2)
    offset = (circumference * (100 - percent) / 100.0).round(2)
    tag.div(class: "lms-ring lms-ring-#{size}", role: 'img', aria: { label: "#{label}: #{percent}%" }) do
      safe_join([
        tag.svg(viewBox: '0 0 36 36', aria: { hidden: true }, focusable: 'false') do
          safe_join([
            tag.circle(class: 'lms-ring-track', cx: 18, cy: 18, r: radius),
            tag.circle(class: 'lms-ring-fill', cx: 18, cy: 18, r: radius, style: "stroke-dasharray: #{circumference}; stroke-dashoffset: #{offset}")
          ])
        end,
        tag.span(percent == 100 ? '✓' : "#{percent}%", class: 'lms-ring-text', aria: { hidden: true })
      ])
    end
  end

  def lms_minutes(minutes) = t('lms.minutes', count: minutes.to_i)

  # [key, term, definition] for the glossary keys a lesson used.
  def lms_terms_used(course, keys)
    keys.filter_map { |key| course.glossary[key]&.then { |(term, definition)| [key, term, definition] } }
  end
end
