# frozen_string_literal: true

# Turns an assistant-submitted request (an AgentFeedback row of a request kind)
# into tracked work, or closes it, on a reviewer's decision (#406):
#
#   accept!  — opens a task that keeps the requester, the date asked and the text,
#              and links back to the request and its chat;
#   merge!   — the request duplicates an existing task: it is linked to that task
#              and a comment on the task records who asked, when and what;
#   decline! — closes the request with a reason the requester can read.
#
# The reviewer needs the project/task write permission (Projects::TaskPolicy#create?).
# Everything happens in the current tenant; a decision is made once, under a row
# lock, and each one is written to the Activity log. The chat that produced the
# request stays a separate conversation record (#408): only its link is copied.
class RequestTriage
  class Error < StandardError; end
  class Denied < Error; end

  TITLE_MAX = 200

  def self.accept!(...) = new(...).accept!
  def self.merge!(...) = new(...).merge!
  def self.decline!(...) = new(...).decline!

  # Who may work the queue: the people who can add tasks.
  def self.reviewer?(user)
    user.present? && Projects::TaskPolicy.new(user, Projects::Task).create?
  end

  def initialize(request:, user:, params: {})
    @request = request
    @user = user
    @params = params.to_h.with_indifferent_access
  end

  def accept!
    decide!('accepted') do
      project = chosen_project
      task = Projects::Task.create!(
        project: project, title: (AgentFeedback.clean(@params[:title], TITLE_MAX) || @request.summary).first(TITLE_MAX),
        priority: Projects::Task::PRIORITIES.include?(@params[:priority].to_s) ? @params[:priority].to_s : FeedbackTask::PRIORITIES.fetch(@request.severity, 'medium'),
        assignee_id: chosen_assignee_id(project), description: description
      )
      ActivityLogger.log('task_created_from_request', subject: task, actor: @user, details: "request=#{@request.id}; requester=#{requester_label}")
      task
    end
  end

  def merge!
    decide!('merged') do
      task = Projects::Task.find_by(id: @params[:task_id])
      raise Error, 'Choose the task this request duplicates.' unless task && Projects::TaskPolicy.new(@user, task).update?

      task.comments.create!(user_id: @user.id, body: "Duplicate request merged here.\n\n#{description}".first(Projects::TaskComment::MAX_LENGTH))
      ActivityLogger.log('request_merged_into_task', subject: task, actor: @user, details: "request=#{@request.id}; requester=#{requester_label}")
      task
    end
  end

  def decline!
    reason = AgentFeedback.clean(@params[:reason], AgentFeedback::DECLINE_REASON_MAX, multiline: true)
    raise Error, 'Say why the request is rejected; the requester will read it.' if reason.blank?

    decide!('declined', reason: reason) { nil }
  end

  STATUS_FOR = { 'accepted' => 'planned', 'merged' => 'planned', 'declined' => 'wont_fix' }.freeze

  private

  def decide!(decision, reason: nil)
    raise Denied, 'You do not have permission to triage requests.' unless self.class.reviewer?(@user)

    task = nil
    AgentFeedback.transaction do
      @request.lock!
      raise Error, "Request ##{@request.id} was already #{@request.triage_label&.downcase || 'handled'}." unless @request.awaiting_triage?

      task = yield
      @request.update!(triage_decision: decision, decline_reason: reason, task_id: task&.id || @request.task_id,
        status: STATUS_FOR.fetch(decision), triaged_by: @user, triaged_at: Time.current)
    end
    ActivityLogger.log("assistant_request_#{decision}", subject: @request, actor: @user,
      details: ["request=#{@request.id}", ("task=#{task.id}" if task), "requester=#{requester_label}", ("reason=#{reason}" if reason)].compact.join('; ').first(500))
    task
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.to_sentence
  end

  def chosen_project
    return FeedbackTask.project if @params[:project_id].blank?

    project = Projects::Project.find_by(id: @params[:project_id])
    raise Error, 'Choose a project in this workspace.' unless project

    project
  end

  def chosen_assignee_id(project)
    return FeedbackTask.owner&.id&.to_s if @params[:assignee_id].blank? && project.name == FeedbackTask::PROJECT_NAME
    return if @params[:assignee_id].blank?

    person = User.find_by(id: @params[:assignee_id], tenant_id: Current.tenant_id, active: true)
    raise Error, 'Choose someone in this workspace.' unless person

    person.id.to_s
  end

  def requester = @request.user
  def requester_label = requester&.display_name || @request.agent_name || 'an assistant'

  # The request as asked: its words, who asked, when, and where it came from.
  def description
    asked = I18n.l(@request.created_at.to_date, format: :long)
    via = [@request.conversation_label || @request.agent_name, @request.conversation_url].compact.join(' ')
    footer = ["Requested by #{requester_label} on #{asked}#{" via #{via}" if via.present?}.",
              "Request ##{@request.id}: /feedback_reports/#{@request.id}"]
    [@request.summary, @request.details.to_s.first(FeedbackTask::DESCRIPTION_MAX).presence, footer.join("\n")].compact.join("\n\n")
  end
end
