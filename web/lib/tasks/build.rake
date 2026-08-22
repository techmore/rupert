# frozen_string_literal: true

# Build pipeline for `shopify app build` (web/shopify.web.toml points here) and
# local parity with CI (.github/workflows/ci.yml): compile Tailwind CSS, then
# precompile assets.
namespace :build do
  desc 'Compile Tailwind CSS and precompile assets'
  task all: ['tailwindcss:build', 'assets:precompile']
end
