# frozen_string_literal: true

# A report written by an external AI assistant through the MCP submit_feedback
# tool: a bug, a struggle, a task outcome, a suggestion. Everything an assistant
# writes is untrusted text — stored length-capped, shown escaped, never
# executed or followed as an instruction. The owner triages it in-app.
class AgentFeedback < ApplicationRecord
  include TenantScoped

  KINDS = {
    'bug' => 'Bug', 'struggle' => 'Struggle', 'task_report' => 'Task report',
    'suggestion' => 'Suggestion', 'question' => 'Question', 'report_issue' => 'Report issue',
    'request' => 'Request', 'direction' => 'Direction'
  }.freeze
  # agent = an AI assistant over MCP, app = the ladybug in Rupert, buzz = a teammate's Buzz chat message (Buzz is retired; kept for older reports).
  SOURCES = %w[agent app buzz].freeze
  SEVERITIES = %w[low normal high].freeze
  STATUSES = {
    'new' => 'New', 'triaged' => 'Triaged', 'planned' => 'Planned', 'done' => 'Done', 'wont_fix' => "Won't fix"
  }.freeze
  SUMMARY_MAX = 200
  DETAILS_MAX = 5000
  CONTEXT_MAX_BYTES = 4000
  NOTES_MAX = 5000
  # Triage of assistant-submitted requests (#406). A request becomes tracked work only
  # when a reviewer accepts it (new task) or merges it into an existing task; a decline
  # keeps the reason so the requester can read it. Nil = still waiting in the queue.
  # These are the transitions the "request" type keeps in the shared Project table (#407).
  REQUEST_KINDS = %w[request suggestion direction].freeze
  TRIAGE_DECISIONS = { 'accepted' => 'Approved', 'merged' => 'Merged', 'declined' => 'Rejected' }.freeze
  CONVERSATION_KINDS = { 'ask_rupert' => 'Ask Rupert', 'team_chat' => 'Team chat' }.freeze
  DECLINE_REASON_MAX = 1000

  belongs_to :api_access_token, optional: true
  belongs_to :user, optional: true
  belongs_to :triaged_by, class_name: 'User', optional: true
  belongs_to :task, class_name: 'Projects::Task', optional: true
  has_many :attachments, class_name: 'FeedbackAttachment', dependent: :destroy

  validates :tenant_id, presence: true
  validates :kind, inclusion: { in: KINDS.keys }
  validates :severity, inclusion: { in: SEVERITIES }
  validates :status, inclusion: { in: STATUSES.keys }
  validates :source, inclusion: { in: SOURCES }
  validates :source_ref, length: { maximum: 120 }
  validates :source_sender, :ready_marked_by, length: { maximum: 160 }
  validates :summary, presence: true, length: { maximum: SUMMARY_MAX }
  validates :details, length: { maximum: DETAILS_MAX }
  validates :related_tool, :agent_name, :agent_model, length: { maximum: 100 }
  validates :related_reference, length: { maximum: 300 }
  validates :context, length: { maximum: CONTEXT_MAX_BYTES }
  validates :owner_notes, length: { maximum: NOTES_MAX }
  validates :triage_decision, inclusion: { in: TRIAGE_DECISIONS.keys }, allow_nil: true
  validates :decline_reason, length: { maximum: DECLINE_REASON_MAX }
  validates :decline_reason, presence: true, if: -> { triage_decision == 'declined' }
  validates :conversation_kind, inclusion: { in: CONVERSATION_KINDS.keys }, allow_nil: true
  # Only a path inside Rupert (built by the chat itself), never an outside address.
  validates :conversation_url, length: { maximum: 300 }, format: { with: %r{\A/(?![/\\])\S*\z}, allow_nil: true }

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  # New reports go to GitHub (see GithubIssues) once the token is set.
  after_create_commit { GithubIssuePostJob.perform_later(id) if GithubIssues.configured? }
  scope :reported_by, ->(user) { where(user_id: user.id) }
  # Requests an assistant filed: over MCP or approved from team chat (source agent/buzz), or from an Ask Rupert chat.
  scope :assistant_requests, -> { where(kind: REQUEST_KINDS).where('agent_feedbacks.source IN (?) OR agent_feedbacks.conversation_kind IS NOT NULL', %w[agent buzz]) }
  # Waiting for a reviewer: not decided, not already tracked by a task, not closed some other way.
  scope :awaiting_triage, -> { assistant_requests.where(triage_decision: nil, task_id: nil).where(status: %w[new triaged]) }

  # Removes control characters (except newlines/tabs in long text) and trims.
  def self.clean(value, max, multiline: false)
    return nil if value.nil?

    text = value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
    text = multiline ? text.gsub(/[^\P{Cc}\n\t]/, '') : text.gsub(/\p{Cc}/, ' ')
    text.strip.first(max).presence
  end

  def kind_label = KINDS.fetch(kind, kind)
  def status_label = STATUSES.fetch(status, status)
  def triage_label = TRIAGE_DECISIONS[triage_decision]
  def conversation_label = CONVERSATION_KINDS[conversation_kind]
  def assistant_request? = REQUEST_KINDS.include?(kind) && (%w[agent buzz].include?(source) || conversation_kind.present?)
  def awaiting_triage? = assistant_request? && triage_decision.nil? && task_id.nil? && %w[new triaged].include?(status)

  def context_hash
    context.present? ? JSON.parse(context) : {}
  rescue JSON::ParserError
    {}
  end

  # What the person who filed an in-app report may see: its status, never owner notes or attachments.
  def reporter_view
    agent_view.merge(task_id: task_id)
  end

  # What an assistant may see about its own submission: never owner notes.
  def agent_view
    { id: id, kind: kind, severity: severity, status: status, summary: summary, related_tool: related_tool,
      submitted_at: created_at&.iso8601, updated_at: updated_at&.iso8601 }.merge({ triage_decision: triage_decision, decline_reason: decline_reason }.compact)
  end
end
