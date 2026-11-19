# frozen_string_literal: true

require 'test_helper'
require 'yaml'
require_relative '../../support/ask_rupert_helper'
require Rails.root.join('script/ask_rupert_eval/scoring')

# The local-model eval (script/ask_rupert_eval) asks a model server the same
# prompt and tool schemas Ask Rupert's local provider sends. snapshot.json holds
# them, rendered from the real Brain, Tools and Guide for a fixture admin on a
# frozen date. Rebuild it after changing the prompt, tools or navigation:
#
#   UPDATE_LOCAL_EVAL=1 bin/rails test test/services/ask_rupert/local_eval_test.rb
class AskRupertLocalEvalTest < ActiveSupport::TestCase
  include AskRupertHelper

  DIR = Rails.root.join('script/ask_rupert_eval')
  CONTEXT_MARK = 'CONTEXT (from Rupert'
  TODAY = Time.zone.local(2026, 10, 15, 10, 0)

  def cases = YAML.safe_load_file(DIR.join('cases.yml'))['cases']

  def render
    travel_to TODAY
    user = person('admin')
    Current.user = user
    base = nil
    contexts = {}
    nav = {}
    tools = nil
    cases.each do |item|
      _conversation, message = pending_turn(user, item['question'])
      brain = AskRupert::Brain.new(message, config: AskRupert::Config.new({}), providers: [])
      prompt = brain.send(:system_prompt, item['question'])
      head, context = prompt.split(CONTEXT_MARK, 2)
      raise "no CONTEXT section in the Ask Rupert prompt for #{item['id']}" unless context

      base ||= head
      raise "the prompt before CONTEXT changed between cases (#{item['id']})" unless base == head

      contexts[item['id']] = "#{CONTEXT_MARK}#{context}"
      toolbox = AskRupert::Tools.new(user: user, conversation: message.conversation, message: message)
      gateway = AskRupert::Providers::LocalGateway.new
      tools ||= toolbox.definitions.map { |definition| gateway.send(:definition, definition) }
      query = item['nav_query'] || item['question']
      nav[item['id']] = %w[where_is how_do_i].to_h { |name| [name, toolbox.send(name, { 'query' => query }).text] }
    end
    JSON.parse(JSON.generate({ 'generated_for' => TODAY.to_date.iso8601, 'user' => 'fixture admin', 'system_base' => base,
      'tools' => tools, 'contexts' => contexts, 'nav' => nav }))
  end

  test 'snapshot matches the prompt, tools and navigation Ask Rupert sends today' do
    fresh = render
    path = DIR.join('snapshot.json')
    if ENV['UPDATE_LOCAL_EVAL'].present?
      File.write(path, "#{JSON.pretty_generate(fresh)}\n")
      skip 'snapshot.json rewritten'
    end
    stored = JSON.parse(File.read(path))
    hint = 'Ask Rupert changed; run UPDATE_LOCAL_EVAL=1 bin/rails test test/services/ask_rupert/local_eval_test.rb'
    assert_equal fresh['tools'], stored['tools'], hint
    assert_equal fresh['system_base'], stored['system_base'], hint
    assert_equal fresh['contexts'], stored['contexts'], hint
    assert_equal fresh['nav'], stored['nav'], hint
  end

  test 'cases are well formed and only expect tools Ask Rupert offers' do
    offered = JSON.parse(File.read(DIR.join('snapshot.json')))['tools'].map { |tool| tool.dig('function', 'name') }
    ids = cases.map { |item| item['id'] }
    assert_equal ids.uniq, ids
    assert_operator ids.length, :>=, 30
    cases.each do |item|
      expect = item.fetch('expect')
      wanted = [expect.fetch('tool')] + Array(expect['also'])
      assert_empty wanted - offered - ['none'], item['id']
      Array(expect['answer']).concat(Array(expect['forbid'])).each { |pattern| Regexp.new(pattern) }
      (item['results'] || {}).each_key do |key|
        assert_includes offered, key.split(':').first, "#{item['id']} has results for a tool that is not offered"
      end
    end
  end

  test 'cases hold no real-looking secrets or contact details' do
    text = File.read(DIR.join('cases.yml'))
    refute_match(/sk-[A-Za-z0-9]{10,}|api[_-]?key\s*[:=]/i, text)
    emails = text.scan(/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/).uniq
    assert_empty emails - ['help@example.com'], 'only example.com addresses belong in the eval'
  end

  test 'scoring checks the first call, its arguments and the answer' do
    expect = { 'tool' => 'run_report', 'args' => { 'report' => 'sales_summary', 'arguments.from' => '2026-10-14', 'arguments.source' => '/^sq/i' },
               'answer' => ['4,?812\.40'], 'forbid' => ['\$0\b'] }
    good = { 'name' => 'run_report', 'arguments' => { 'report' => 'sales_summary', 'arguments' => { 'from' => '2026-10-14', 'source' => 'square' } } }
    assert_equal [true, nil], AskRupertEval::Scoring.first_call_ok(expect, good)
    wrong_date = good.merge('arguments' => { 'report' => 'sales_summary', 'arguments' => { 'from' => '2026-10-13', 'source' => 'square' } })
    refute AskRupertEval::Scoring.first_call_ok(expect, wrong_date).first
    refute AskRupertEval::Scoring.first_call_ok(expect, nil).first
    assert AskRupertEval::Scoring.first_call_ok({ 'tool' => 'none', 'also' => ['where_is'] }, { 'name' => 'where_is', 'arguments' => {} }).first
    assert AskRupertEval::Scoring.first_call_ok({ 'tool' => 'x', 'args' => { 'to' => ['2026-10-15', nil] } }, { 'name' => 'x', 'arguments' => {} }).first

    assert AskRupertEval::Scoring.answer_ok(expect, 'Yesterday: $4,812.40 across 63 orders.', []).first
    refute AskRupertEval::Scoring.answer_ok(expect, 'Square was $0 yesterday, total $4812.40.', []).first
    assert_equal [false, 'invented path /reports/made_up'],
      AskRupertEval::Scoring.answer_ok({}, 'See [Sales](/reports/sales) or [More](/reports/made_up).', ['/reports/sales'])
  end

  test 'schema checks match what the local gateway refuses' do
    schema = { 'type' => 'object', 'required' => ['kind'], 'additionalProperties' => false,
               'properties' => { 'kind' => { 'type' => 'string', 'enum' => %w[bug request] }, 'summary' => { 'type' => 'string', 'maxLength' => 5 } } }
    assert_nil AskRupertEval::Scoring.schema_problem(schema, { 'kind' => 'bug' })
    assert_equal 'missing kind', AskRupertEval::Scoring.schema_problem(schema, {})
    assert_equal 'unknown argument extra', AskRupertEval::Scoring.schema_problem(schema, { 'kind' => 'bug', 'extra' => 1 })
    assert_equal 'kind is not an allowed value', AskRupertEval::Scoring.schema_problem(schema, { 'kind' => 'praise' })
    assert_equal 'summary is too long', AskRupertEval::Scoring.schema_problem(schema, { 'kind' => 'bug', 'summary' => 'too long' })
  end

  test 'summary reports counts and latency percentiles' do
    rows = [{ 'tool_ok' => true, 'answer_ok' => true, 'ttft_ms' => 100, 'total_ms' => 900, 'tokens_out' => 10 },
            { 'tool_ok' => false, 'answer_ok' => true, 'ttft_ms' => 300, 'total_ms' => 1500, 'tokens_out' => 5, 'error' => 'x' }]
    summary = AskRupertEval::Scoring.summary(rows)
    assert_equal [2, 1, 2, 1, 1], summary.values_at('cases', 'tool_ok', 'answer_ok', 'both_ok', 'protocol_errors')
    assert_equal 100, summary['ttft_ms_p50']
    assert_equal 1500, summary['total_ms_p90']
  end
end
