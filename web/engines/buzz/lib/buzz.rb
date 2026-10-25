# frozen_string_literal: true

# Buzz: an optional, self-contained module that shows the team's Buzz (Nostr)
# relay channels inside Rupert. Everything it needs lives in web/engines/buzz;
# see the README there. config/application.rb requires this file only when
# RUPERT_BUZZ_ENABLED=1, so while the module is off none of it is loaded.
module Buzz
  # Buzz::Message -> buzz_messages, the tables kept from the retired integration.
  def self.table_name_prefix = 'buzz_'
end

require_relative 'buzz/engine'
