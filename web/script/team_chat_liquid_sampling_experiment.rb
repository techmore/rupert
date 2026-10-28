# frozen_string_literal: true

# Isolated synthetic experiment; never load this override in production.
abort 'Only the isolated LFM3 text finance experiment may change sampling.' unless Rails.env.test? &&
  ENV['MODE'] == 'run' && ENV['BATTERY'] == 'finance' && ENV['AGENT'] == 'lfm3-text' &&
  ENV['RUPERT_SQLITE_DATABASE_TEST'].to_s.include?('benchmark') &&
  ENV['RUPERT_LOCAL_LLM_URL'] == 'http://127.0.0.1:18081/v1'

module LiquidSamplingExperiment
  def native_chat
    super.with_temperature(0.1)
  end
end

TeamChat::Agent.prepend(LiquidSamplingExperiment)
load Rails.root.join('script/team_chat_fixture_battery.rb')
