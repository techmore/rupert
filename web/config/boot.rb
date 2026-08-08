# frozen_string_literal: true

require "dotenv"
Dotenv.load(File.expand_path("../../.env", __dir__))

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
ENV["HOST"] = "https://#{ENV["HOST"]}" unless ENV["HOST"]&.match(%r{https?://})

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.
