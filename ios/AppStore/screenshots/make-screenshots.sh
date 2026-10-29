#!/usr/bin/env bash
# Remakes the App Store screenshots in this folder from Rupert's real pages.
#
# Run it in a test container (SER8), never against production: it builds a throwaway
# development database in a temp folder, seeds the fictional review workspace into it
# (bin/rails rupert:app_review_demo, with a random password that lives only in this
# shell), starts Rails on 127.0.0.1, captures with make-screenshots.mjs and cleans up.
#
#   ios/AppStore/screenshots/make-screenshots.sh [path/to/web]
#
# Needs Ruby and the bundle for web/, Node with Playwright and its Chromium (set
# PLAYWRIGHT_MODULE=/path/to/node_modules/playwright/index.mjs if it is installed elsewhere),
# and the Inter font (fonts-inter) so text resembles San Francisco.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
web=$(cd "${1:-$here/../../../web}" && pwd)
port=${PORT:-3990}
tmp=$(mktemp -d)
server=

cleanup() {
  [ -n "$server" ] && kill "$server" 2>/dev/null && wait "$server" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

export RAILS_ENV=development RUPERT_DB_ADAPTER=sqlite3 RUPERT_SQLITE_DATABASE_DEVELOPMENT="$tmp/screens.sqlite3"
export SHOPIFY_API_KEY=${SHOPIFY_API_KEY:-screenshots} SHOPIFY_API_SECRET=${SHOPIFY_API_SECRET:-screenshots} HOST=${HOST:-localhost}
REVIEW_PASSWORD=$(ruby -rsecurerandom -e 'print SecureRandom.alphanumeric(24)')
export REVIEW_PASSWORD

cd "$web"
bin/rails db:prepare >"$tmp/prepare.log" 2>&1 || { cat "$tmp/prepare.log"; exit 1; }
bin/rails tailwindcss:build >/dev/null 2>&1
count_id=$(bin/rails rupert:app_review_demo | tee /dev/stderr | sed -n 's/.*draft count \([^ .]*\)\..*/\1/p')
[ -n "$count_id" ] || { echo "No draft count id from rupert:app_review_demo" >&2; exit 1; }

bin/rails server -p "$port" -b 127.0.0.1 -P "$tmp/server.pid" >"$tmp/server.log" 2>&1 &
server=$!
for _ in $(seq 1 90); do
  curl -fsS -o /dev/null "http://127.0.0.1:$port/up" 2>/dev/null && break
  # /proc, not kill -0: some containers (Incus with AppArmor) refuse even that signal.
  [ -d "/proc/$server" ] || { cat "$tmp/server.log"; exit 1; }
  sleep 1
done

node "$here/make-screenshots.mjs" --base-url "http://127.0.0.1:$port" --count-id "$count_id" --out "$here"
