# frozen_string_literal: true

# Shared pieces for the Rupert stock screens (master_stock/*): signed numbers,
# short ages, people's names and the "what each platform shows" chips.
module RupertStockHelper
  MINUS = "−"

  # +3, −3 (a real minus sign), 0.
  def signed_units(value)
    return '—' if value.nil?
    return value.to_s if value.zero?

    value.positive? ? "+#{value}" : "#{MINUS}#{value.abs}"
  end

  # "8 min", "3 h", "2 d": compact enough for a table cell.
  def short_age(time, now: Time.current)
    return 'never' if time.nil?

    seconds = (now - time).to_i
    return 'just now' if seconds < 60
    return "#{seconds / 60} min" if seconds < 3600
    return "#{seconds / 3600} h" if seconds < 86_400

    "#{seconds / 86_400} d"
  end

  def counted_label(balance)
    return 'Never counted here' if balance.nil?
    return 'Not counted yet' if balance.counted_at.nil?

    "Counted #{short_age(balance.counted_at)} ago"
  end

  # The person behind a ledger email, by name when they have an account here.
  def stock_person(email)
    @stock_people ||= {}
    @stock_people.fetch(email) do
      @stock_people[email] = User.find_by(email: email)&.display_name.presence || email.to_s.split('@').first
    end
  end

  # One platform's stored reading next to Rupert's number. The word carries the state
  # (matches / differs / old read / unknown), so colour is never the only signal.
  # Returns nil when the item has no link on that platform at the site.
  def platform_reading_chip(platform, row)
    return if row.nil?

    label = MasterStock.platform_label(platform)
    shown = row.observed.to_i.negative? ? "#{MINUS}#{row.observed.abs}" : row.observed
    stale = row.observed_at.nil? || row.observed_at < MasterStock::PushPreview::FRESH_FOR.ago
    tone, text, title = if row.observed.nil?
      ['pill-taupe', "#{label} unknown", row.reasons.first]
    elsif row.target.nil?
      ['pill-taupe', "#{label} #{shown}", "#{label} shows #{shown}. Count it in Rupert to compare."]
    elsif row.observed == row.target
      ['pill-fern', "#{label} #{shown} · matches", "#{label} shows the same #{shown} as Rupert."]
    else
      diff = row.observed - row.target
      ['pill-clay', "#{label} #{shown} · #{diff.positive? ? "#{diff} more" : "#{diff.abs} fewer"}",
       "#{label} shows #{shown}; Rupert has #{row.target}."]
    end
    if stale && !row.observed.nil?
      text = "#{text} · #{short_age(row.observed_at)} old"
      tone = 'pill-taupe' if tone == 'pill-fern'
      title = "#{title} Read #{short_age(row.observed_at)} ago, so it may be out of date."
    end
    tag.span(text, class: "#{tone} stock-reading", title: title, data: { platform: platform })
  end
end
