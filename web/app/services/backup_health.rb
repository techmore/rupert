# frozen_string_literal: true

# One plain answer to "are backups working?", for the owner: Settings → Backups, the bell, the dashboard banner, the
# status bar and the hourly BackupHealthAlertJob all read it. It only interprets what already exists: the active
# BackupEncryptionKey and the per-layer reports in BackupStatus (written by the backup scripts).
#
#   off        no active backup key: every scheduled backup is refused (the server never writes an unencrypted one)
#   starting   the key was just turned on and the first encrypted backup has not landed yet
#   ok         the layers that run on this server are reporting fresh, encrypted backups
#   attention  a layer failed, or has not reported inside its schedule
#
# The rolling snapshot and the local set always count. The off-host copy and the weekly check count once they have
# reported at least once (they are installed on the host, outside the app). The off-machine mirror and the
# recovery-kit drill are extra protection: listed on the page, never an alarm on every page.
#
# A layer only reports when its own timer fires, so after a key is turned on each one gets a single interval of its
# schedule to make its first encrypted backup before its older "refused: no key" report counts as a failure.
class BackupHealth
  CORE = %w[frequent local].freeze
  WHEN_INSTALLED = %w[offhost verify].freeze
  EXTRA = %w[offsite restore].freeze
  PROBLEM_STATES = %w[failed stale missing].freeze

  Check = Struct.new(:layer, :state, keyword_init: true) do
    delegate :key, :label, :every, :report, to: :layer
    def ok? = state == 'ok'
    def waiting? = state == 'waiting'
    def problem? = PROBLEM_STATES.include?(state)
  end

  attr_reader :key, :now

  class << self
    def current = new

    # Alarms are for real servers. Development and test databases have no backup timers; tests turn this on.
    def alerts_enabled? = Rails.env.production?

    def alert_for(user)
      return unless alerts_enabled? && user&.super_admin?

      health = current
      health if health.alert?
    rescue StandardError => e
      Rails.logger.warn("[backup-health] #{e.class}")
      nil
    end
  end

  def initialize(layers: BackupStatus.layers, key: BackupEncryptionKey.current, now: Time.current)
    @layers = layers.index_by(&:key)
    @key = key
    @now = now
  end

  def state
    return :off unless key
    return :attention if problems.any?

    last_good_at ? :ok : :starting
  end

  def off? = state == :off
  def ok? = state == :ok
  def starting? = state == :starting
  def alert? = %i[off attention].include?(state)

  # Layers whose trouble is worth an alarm.
  def checks
    @checks ||= (CORE + WHEN_INSTALLED).filter_map do |name|
      layer = @layers[name]
      next unless layer
      next if WHEN_INSTALLED.include?(name) && !layer.reported?

      Check.new(layer: layer, state: effective_state(layer))
    end
  end

  def extras
    @extras ||= EXTRA.filter_map { |name| (layer = @layers[name]) && Check.new(layer: layer, state: layer.state(now)) }
  end

  def problems = key ? checks.select(&:problem?) : []
  def waiting = key ? checks.select(&:waiting?) : []

  # When the newest encrypted, integrity-checked backup was written on this server.
  def last_good_at
    return unless key

    checks.select { |check| CORE.include?(check.key) && check.ok? }.filter_map { |check| check.report.at }.max
  end

  # When the weekly check last confirmed the copies outside the container against their digests.
  def verified_at
    check = checks.find { |entry| entry.key == 'verify' }
    check.report.at if check&.ok?
  end

  def title
    case state
    when :off then 'Backups are off'
    when :attention then 'Backups need attention'
    when :starting then 'Backups are on'
    else 'Backups are working'
    end
  end

  def summary
    case state
    when :off
      'Nothing is being backed up. If this server were lost today, your sales, stock and time records could not be recovered. Turning backups on takes about two minutes.'
    when :attention
      "#{problems.map { |check| problem_text(check) }.join(' ')} #{last_good_text}".strip
    when :starting
      'The first encrypted backup is being made. It appears here within about five minutes.'
    else
      last_good_text
    end
  end

  def link_label = off? ? 'Turn on backups' : 'Open Backups'

  def problem_text(check)
    report = check.report
    return "#{check.label} has never run on this server." unless report

    age = report.at ? "#{ago(report.at)} ago" : 'at an unknown time'
    return "#{check.label} has not run since #{age} (expected #{check.every})." if check.state == 'stale'

    reason = check.layer.evidence_issue(now) || report.message.to_s.first(200).presence || 'no reason given'
    "#{check.label} failed #{age}: #{reason.chomp('.')}."
  end

  private

  def last_good_text
    last_good_at ? "Last good backup: #{ago(last_good_at)} ago." : 'There is no good backup yet.'
  end

  def ago(time) = ActionController::Base.helpers.distance_of_time_in_words(time, now)

  def effective_state(layer)
    raw = layer.state(now)
    return raw if raw == 'ok' || key.nil?

    reported_since_key = layer.report&.at && layer.report.at >= key.activated_at
    return 'waiting' if !reported_since_key && now < key.activated_at + layer.stale_after

    raw
  end
end
