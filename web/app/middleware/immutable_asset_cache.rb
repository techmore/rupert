# frozen_string_literal: true

# Fingerprinted assets (name-<sha256>.ext under the assets prefix) never change:
# a new build gives them a new name. Telling browsers so lets every page after the
# first load its CSS and JavaScript from cache without asking the server again.
#
# The landing page's static files (public/marketing: its stylesheet and screenshots)
# have no fingerprint, so they get a day, then are served from cache while the browser
# rechecks them for up to a week. The page bumps landing.css?v= when the CSS changes.
# Only static file types the app did not already give a header: the signed-in
# Marketing module also lives under /marketing and must stay private.
class ImmutableAssetCache
  FINGERPRINT = /-[0-9a-f]{40,}\.[a-z0-9]+\z/
  HEADER = 'public, max-age=31536000, immutable'
  MARKETING_FILE = %r{\A/marketing/[\w./-]+\.(?:css|webp|avif|png|jpe?g|svg|woff2?)\z}
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
    elsif status == 200 && path.match?(MARKETING_FILE) && headers['cache-control'].blank?
      headers['cache-control'] = MARKETING_HEADER
    end
    [status, headers, body]
  end
end
