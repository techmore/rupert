# frozen_string_literal: true

# Fingerprinted assets (name-<sha256>.ext under the assets prefix) never change:
# a new build gives them a new name. Telling browsers so lets every page after the
# first load its CSS and JavaScript from cache without asking the server again.
#
# The marketing page's files (/marketing: its stylesheet and screenshots) have no
# fingerprint, so they get a day, then are served from cache while the browser
# rechecks them for up to a week. The page bumps landing.css?v= when the CSS changes.
class ImmutableAssetCache
  FINGERPRINT = /-[0-9a-f]{40,}\.[a-z0-9]+\z/
  HEADER = 'public, max-age=31536000, immutable'
  MARKETING_PREFIX = '/marketing/'
  MARKETING_HEADER = 'public, max-age=86400, stale-while-revalidate=604800'

  def initialize(app, prefix: Rails.application.config.assets.prefix)
    @app = app
    @prefix = "#{prefix.chomp('/')}/"
  end

  def call(env)
    status, headers, body = @app.call(env)
    path = env['PATH_INFO'].to_s
    if status == 200 && path.start_with?(@prefix) && path.match?(FINGERPRINT)
      headers['cache-control'] = HEADER
    elsif status == 200 && path.start_with?(MARKETING_PREFIX)
      headers['cache-control'] = MARKETING_HEADER
    end
    [status, headers, body]
  end
end
