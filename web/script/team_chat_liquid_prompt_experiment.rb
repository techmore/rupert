# frozen_string_literal: true

# Synthetic, isolated experiment: keep the ordinary rules and append a short
# model-specific plan. Do not load in production or change the live benchmark.
abort 'Only the isolated LFM3 text finance experiment may use this prompt.' unless Rails.env.test? &&
  ENV['MODE'] == 'run' && ENV['BATTERY'] == 'finance' && ENV['AGENT'] == 'lfm3-text' &&
  ENV['RUPERT_SQLITE_DATABASE_TEST'].to_s.include?('benchmark') &&
  ENV['RUPERT_LOCAL_LLM_URL'] == 'http://127.0.0.1:18081/v1'

module LiquidTaxExperiment
  def system_prompt
    super + <<~TEXT

      ## Answering a tax question efficiently
      First identify the requested period and which sources the person named.
      For tax collected across sources, call sales_tax_report for the exact dates. The sources can overlap: report each separately and do not add them.
      For recorded online and Square tax by source, call metric with name tax_collected and the requested period. For effective tax rate, call metric with name effective_tax_rate and the requested period.
      After receiving the relevant result, answer the question directly using the returned values, currencies, sources and period. If a value is unavailable, say so; never turn unknown into zero.
      Do not repeat a tool call with the same arguments. Do not call unrelated tools or compute amounts or percentages yourself. Follow the existing privacy, approval and evidence rules.
    TEXT
  end
end
TeamChat::Agent.prepend(LiquidTaxExperiment)
load Rails.root.join('script/team_chat_fixture_battery.rb')
