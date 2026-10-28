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
end
