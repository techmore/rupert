# frozen_string_literal: true

# Isolated synthetic-fixture runner. The simulated wall clock advances with
# real time so request deadlines and leases still work. Reference lookups alone
# use the fixed anchor after each answer, when the agent's watch has stopped.
require 'active_support/testing/time_helpers'
STDOUT.sync = true
abort 'Only an isolated benchmark test database is allowed.' unless Rails.env.test? && ENV['RUPERT_SQLITE_DATABASE_TEST'].to_s.include?('benchmark')
abort 'Fixture model server must use the local proxy.' unless ENV['RUPERT_LOCAL_LLM_URL'] == 'http://127.0.0.1:18081/v1'
anchor = Time.zone.parse(ENV.fetch('BENCHMARK_ANCHOR'))
offset = anchor.to_f - Time.now.to_f
Time.singleton_class.class_eval do
  alias_method :fixture_real_now, :now
  define_method(:now) { |*args, **kwargs| fixture_real_now(*args, **kwargs) + offset }
end

module FixtureReferenceClock
  private

  def reference_for(item)
    clock = Object.new.extend(ActiveSupport::Testing::TimeHelpers)
    clock.travel_to(Time.zone.parse(ENV.fetch('BENCHMARK_ANCHOR'))) { super }
  end
end
TeamChat::Battery.prepend(FixtureReferenceClock)
Current.tenant = Tenant.find('test-tenant-default')
Current.user = User.find_by!(email: 'admin@example.com', tenant_id: Current.tenant.id)
set = ENV.fetch('BATTERY')
items = set == 'bank' ? TeamChat::QuestionBank.battery_items(per: ENV.fetch('PER', '5').to_i) :
  TeamChat::Battery.items(TeamChat::Battery.config_for(set))
cohort_path = ENV.fetch('COHORT')
if ENV.fetch('MODE') == 'capture'
  probe = TeamChat::Battery.new(user: Current.user, agent: 'rupert', items: items, set: set, out: nil)
  cohort = TeamChat::Battery::Cohort.capture(user: Current.user, items: items) { |item| probe.send(:reference_for, item) }
  before = Time.now
  sleep 0.02
  abort 'Fixture clock stopped; refusing to run with broken deadlines.' unless Time.now > before
  cohort.save_file(cohort_path)
  puts "#{set} cohort #{cohort.id}: #{cohort.size} questions, #{cohort.ungradable} ungradable"
elsif ENV['MODE'] == 'run'
  cohort = TeamChat::Battery::Cohort.load_file(cohort_path, user: Current.user)
  runner = TeamChat::Battery.new(user: Current.user, agent: ENV.fetch('AGENT'), items: items, set: set, cohort: cohort, out: $stdout,
    only: ENV['ONLY'].to_s.split(','))
  runner.run
  report = runner.report_markdown
  File.open(ENV.fetch('REPORT'), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(report) }
  puts "Saved run #{runner.run_id}; #{runner.results.size} results; report written."
else
  abort 'MODE must be capture or run.'
end
