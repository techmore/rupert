# frozen_string_literal: true

# GET /.well-known/assetlinks.json: Android's App Links check. Android fetches it, without signing in,
# to decide whether Rupert links (pos.rupertpos.com/chat, /notifications, …) may open in the Rupert app.
# It names the app's package and the SHA-256 fingerprints of the certificates allowed to sign it, from
# RUPERT_ANDROID_CERT_SHA256 (comma-separated, from Play Console → App integrity). Fingerprints are public;
# they live in the environment because they belong to the owner's Play account, not to this repository.
# Without any, the list is empty and links keep opening in the browser.
# A bare controller: no session, sign-in or workspace redirects apply to Android's request.
class AndroidAssetLinksController < ActionController::Base
  PACKAGE = 'com.rupertpos.rupert'
  FINGERPRINT = /\A(?:[0-9A-F]{2}:){31}[0-9A-F]{2}\z/

  def show
    expires_in 1.hour, public: true
    render json: statements
  end

  def self.fingerprints(value = ENV.fetch('RUPERT_ANDROID_CERT_SHA256', ''))
    value.to_s.split(',').map { |entry| entry.strip.upcase }.grep(FINGERPRINT).uniq
  end

  private

  def statements
    fingerprints = self.class.fingerprints
    return [] if fingerprints.empty?

    [{
      relation: ['delegate_permission/common.handle_all_urls'],
      target: { namespace: 'android_app', package_name: PACKAGE, sha256_cert_fingerprints: fingerprints }
    }]
  end
end
