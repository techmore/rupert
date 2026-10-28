# frozen_string_literal: true

require 'test_helper'

class TeamChatUploadEvidenceTest < ActiveSupport::TestCase
  def entry(rows:, arguments: {})
    { 'name' => 'list_uploads', 'arguments' => arguments, 'result' => "Inbox\n#{JSON.generate(rows: rows)}" }
  end

  test 'reports the limits of an empty or populated latest inbox' do
    text = TeamChat::UploadEvidence.render_last([entry(rows: [])])
    assert_includes text, 'cannot determine what happened'
    text = TeamChat::UploadEvidence.render_last([entry(rows: [{ filename: 'statement.csv', status: 'imported' }])])
    assert_includes text, 'statement.csv (imported)'
    assert_includes text, 'cannot confirm whether this is the last file'
  end

  test 'does not use a filtered lookup or infer a specific file' do
    assert_nil TeamChat::UploadEvidence.render_last([entry(rows: [], arguments: { 'query' => 'bank' })])
    assert_nil TeamChat::UploadEvidence.render_last([entry(rows: [], arguments: { 'page' => 2 })])
    assert TeamChat::UploadEvidence.last_upload_question?('@rupert What happened to the last file I tried to import?')
    assert_not TeamChat::UploadEvidence.last_upload_question?('What happened to my last QuickBooks import?')
    assert_not TeamChat::UploadEvidence.last_upload_question?('What happened to my last upload and my tasks?')
  end
end
