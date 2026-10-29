# frozen_string_literal: true

module OpenClockOutsHelper
  # "Clocked in 12 days ago and never clocked out" / "Clocked in 19 hours ago and never clocked out".
  def open_clock_out_label(started_at, at = Time.current)
    hours = ((at - started_at) / 3600).floor
    ago = hours < 48 ? pluralize(hours, 'hour') : pluralize(hours / 24, 'day')
    "Clocked in #{ago} ago and never clocked out"
  end
end
