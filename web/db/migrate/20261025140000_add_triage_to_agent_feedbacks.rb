# frozen_string_literal: true

# Triage of assistant-submitted requests (#406): a reviewer accepts a request
# into a task, merges it into an existing task as a duplicate, or declines it
# with a reason. The chat that produced the request stays its own record
# (#408); the request only keeps a link to it. These columns map one-to-one
# onto the "request" type of the planned shared Project table (#407).
class AddTriageToAgentFeedbacks < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_feedbacks, :triage_decision, :string
    add_column :agent_feedbacks, :decline_reason, :text
    add_column :agent_feedbacks, :conversation_kind, :string
    add_column :agent_feedbacks, :conversation_id, :bigint
    add_column :agent_feedbacks, :conversation_message_id, :bigint
    add_column :agent_feedbacks, :conversation_url, :string
    add_index :agent_feedbacks, %i[tenant_id triage_decision], name: 'idx_agent_feedbacks_triage'
  end
end
