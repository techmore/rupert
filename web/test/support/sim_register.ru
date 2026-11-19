# frozen_string_literal: true

# Rupert with the made-up simulator register (test/support/sim_register.rb). Development only,
# local only:
#
#   bin/rails server -c test/support/sim_register.ru -b 127.0.0.1 -p 3005
require_relative '../../config/environment'
require_relative 'sim_register'

SimRegister.install!
run Rails.application
Rails.application.load_server
