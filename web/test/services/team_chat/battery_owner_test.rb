# frozen_string_literal: true

require 'test_helper'

# The owner question set (config/team_chat/battery_owner.yml): keeps it well formed so a run measures the model, not a typo.
class TeamChatBatteryOwnerTest < ActiveSupport::TestCase
  CADENCES = %w[anchored scope honesty action casual rephrased multi].freeze

  def items = TeamChat::Battery.items(TeamChat::Battery.config_for('owner'))

  test 'the owner set is a runnable question set' do
    assert_includes TeamChat::Battery.sets, 'owner'
    assert_equal 36, items.size
    assert_equal CADENCES.sort, items.map(&:cadence).uniq.sort, 'every gap area is represented'
  end

  test 'ids are unique across every battery file, so scores never collide' do
    ids = Dir[Rails.root.join('config/team_chat/battery*.yml')].flat_map { |path| YAML.safe_load_file(path).fetch('questions').pluck('id') }
    assert_equal ids.size, ids.uniq.size, "duplicate ids: #{ids.tally.select { |_, count| count > 1 }.keys.join(', ')}"
  end

  test 'every question has a written expectation and a known module' do
    items.each do |item|
      assert item.expect.present?, "#{item.id} has no expectation"
      assert_includes TeamChat::Leaderboard::COLUMNS.keys, item.module, "#{item.id} has an unknown module"
    end
  end

  test 'every reference check names a real tool' do
    items.flat_map(&:checks).each do |check|
      name = check.is_a?(Hash) ? check['tool'] : check.to_s
      assert Mcp::Registry.find(name), "unknown tool #{name}"
    end
  end

  test 'anchored questions name their dates so the answer does not move with the run date' do
    items.select { |item| item.cadence == 'anchored' }.each do |item|
      assert_match(/\d{4}-\d{2}-\d{2}|September 2026/, item.question, "#{item.id} is not anchored")
    end
  end

  test 'abstention questions are scored in the honesty column' do
    assert(items.select { |item| item.cadence == 'honesty' }.all? { |item| TeamChat::Leaderboard.column_for('cadence' => item.cadence, 'module' => item.module) == 'honesty' })
  end
end
