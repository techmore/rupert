# frozen_string_literal: true

# The Buzz module's own tests run with the module turned on, in their own process:
#
#   RUPERT_BUZZ_ENABLED=1 bin/rails test engines/buzz/test
#
# The main suite (bin/rails test) runs with it off and proves that state
# (test/integration/buzz_module_disabled_test.rb).
ENV['RUPERT_BUZZ_ENABLED'] = '1'
require_relative '../../../test/test_helper'

unless Rails.application.config.x.buzz_enabled
  abort 'The Buzz module tests need their own run: RUPERT_BUZZ_ENABLED=1 bin/rails test engines/buzz/test'
end

require_relative 'support/buzz_chat_helper'
