# frozen_string_literal: true

require 'test_helper'

class TeamChatComplianceEvidenceTest < ActiveSupport::TestCase
  test 'preserves close blockers and redacts personal details' do
    data = { items: [{ title: 'September: Review payments', area: 'Monthly close', status: 'fix', detail: 'Contact person@example.com' },
                     { title: 'Bank review', area: 'Books', status: 'watch' }, { title: 'Done', status: 'ok' }] }
    text = TeamChat::ComplianceEvidence.render([{ 'name' => 'compliance_check', 'result' => "result\n#{JSON.generate(data)}" }])
    assert_includes text, 'September: Review payments (Monthly close; fix)'
    assert_includes text, 'Bank review (Books; watch)'
    assert_not_includes text, 'person@example.com'
    assert_not_includes text, 'Done'
  end

  test 'does not treat truncated or unrelated results as a clear check' do
    assert_nil TeamChat::ComplianceEvidence.render([{ 'name' => 'compliance_check', 'result' => 'truncated' },
                                                    { 'name' => 'other', 'result' => "result\n{\"items\":[]}" }])
  end

  test 'large results stay parseable and indicate omitted items' do
    items = 30.times.map { |i| { title: "Review #{i}", area: 'Books', status: 'watch', detail: 'a' * 200 } }
    packed = TeamChat::ComplianceEvidence.pack(items: items)
    assert_operator JSON.generate(packed).length, :<=, 5_000
    assert packed['omitted']
    text = TeamChat::ComplianceEvidence.render([{ 'name' => 'compliance_check', 'result' => "result\n#{JSON.generate(packed)}" }])
    assert_includes text, 'Review 0'
    assert_includes text, 'Additional compliance items were omitted'
  end

  test 'bounded results prioritize blockers and preserve their topics' do
    items = 25.times.map { |i| { title: "Done #{i}", status: 'ok' } }
    items << { title: 'Unmatched payment', status: 'fix', topics: %w[payments sales] }
    packed = TeamChat::ComplianceEvidence.pack(items: items)

    assert_equal 'Unmatched payment', packed['items'].first['title']
    assert_equal %w[payments sales], packed['items'].first['topics']
    assert packed['omitted']
    assert_operator JSON.generate(packed).length, :<=, 5_000
  end

  test 'retention status survives bounded packing, including an ok status' do
    items = 25.times.map { |i| { title: "Review #{i}", area: 'Books', status: 'watch', detail: 'needs review' } }
    items << { title: 'Google Drive document retention', area: 'Records', status: 'ok', detail: 'Connected' }
    packed = TeamChat::ComplianceEvidence.pack({ items: items }, requested_title: TeamChat::ComplianceEvidence::RETENTION_TITLE)
    assert_equal 'Google Drive document retention', packed['items'].first['title']
    entries = [{ 'name' => 'compliance_check', 'result' => "result\n#{JSON.generate(packed)}" }]
    assert_equal 'Recorded document-retention status (ok): Connected', TeamChat::ComplianceEvidence.render_retention(entries)
    assert_nil TeamChat::ComplianceEvidence.render_retention([{ 'name' => 'compliance_check', 'result' => 'truncated' }])
    assert TeamChat::ComplianceEvidence.retention_question?('@qwen Is our document retention to Google Drive working?')
    assert_not TeamChat::ComplianceEvidence.retention_question?('Is our document retention to Google Drive working and are backups current?')
    assert_not TeamChat::ComplianceEvidence.retention_question?('Is document retention to Google Drive working with backup status?')
    assert TeamChat::ComplianceEvidence.retention_and_backup_question?('Is our document retention to Google Drive working and are backups current?')
    assert_nil TeamChat::ComplianceEvidence.narrow_title('Is our document retention to Google Drive working and are backups current?')
  end

  test 'focused compliance counts preserve zero, distinguish unknown and retain the requested row' do
    items = 25.times.map { |i| { title: "Review #{i}", area: 'Books', status: 'watch' } }
    items << { title: 'Timesheets awaiting approval', area: 'People', status: 'ok', count: 0 }
    packed = TeamChat::ComplianceEvidence.pack({ items: items }, requested_title: TeamChat::ComplianceEvidence::TIMESHEETS_TITLE)
    entries = [{ 'name' => 'compliance_check', 'result' => "result\n#{JSON.generate(packed)}" }]
    assert_equal 'Recorded non-demo submitted timesheets awaiting approval: 0.', TeamChat::ComplianceEvidence.render_focused_count(entries, TeamChat::ComplianceEvidence::TIMESHEETS_TITLE)
    packed['items'].first['status'] = 'unknown'
    entries.first['result'] = "result\n#{JSON.generate(packed)}"
    assert_nil TeamChat::ComplianceEvidence.render_focused_count(entries, TeamChat::ComplianceEvidence::TIMESHEETS_TITLE)
    assert_equal TeamChat::ComplianceEvidence::BANK_LINES_TITLE, TeamChat::ComplianceEvidence.focused_title('Are there bank statement lines waiting to be matched?')
    assert_equal TeamChat::ComplianceEvidence::TIMESHEETS_TITLE, TeamChat::ComplianceEvidence.focused_title('Are there timesheets waiting for approval and are backups current?')
    assert_nil TeamChat::ComplianceEvidence.narrow_title('Are there timesheets waiting for approval and are backups current?')
  end

  test 'bank line counts are described as decisions rather than proof of matched lines' do
    packed = TeamChat::ComplianceEvidence.pack(items: [{ title: 'Uploaded bank lines have a decision', status: 'watch', count: 2 }])
    entries = [{ 'name' => 'compliance_check', 'result' => "result\n#{JSON.generate(packed)}" }]
    text = TeamChat::ComplianceEvidence.render_focused_count(entries, TeamChat::ComplianceEvidence::BANK_LINES_TITLE)
    assert_includes text, 'awaiting a decision: 2'
    assert_includes text, 'does not establish that every line was matched'
  end

  test 'backup freshness reports only consistent recorded Drive backup evidence' do
    entry = { 'name' => 'backup_freshness', 'result' => "result\n#{JSON.generate(drive: { fresh: true, fresh_within_hours: 8, last_success_age_hours: 2 })}" }
    assert_includes TeamChat::ComplianceEvidence.render_backup_freshness([entry]), 'within the last 8 hours'
    entry['result'] = "result\n#{JSON.generate(drive: { fresh: true, fresh_within_hours: 8, last_success_age_hours: 12 })}"
    assert_nil TeamChat::ComplianceEvidence.render_backup_freshness([entry])
    entry['result'] = "result\n#{JSON.generate(drive: { fresh: nil, fresh_within_hours: 8, last_success_age_hours: nil })}"
    assert_nil TeamChat::ComplianceEvidence.render_backup_freshness([entry])
  end
end
