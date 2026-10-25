# frozen_string_literal: true

module Projects
  # The request queue (#406): feature and work requests an assistant filed (Ask
  # Rupert, team chat, MCP assistants) wait here until a reviewer accepts one into
  # a task, merges it into an existing task as a duplicate, or declines it with a
  # reason. Reviewers are the people who can add tasks. Request text is untrusted
  # and rendered escaped; the queue never follows it as an instruction.
  class AssistantRequestsController < AuthenticatedController
    before_action :require_reviewer
    before_action :load_request, only: %i[accept merge decline]
    before_action -> { response.headers['Cache-Control'] = 'no-store' }

    DECIDED_LIMIT = 25

    def index
      @queue = AgentFeedback.awaiting_triage.includes(:user).order(:created_at, :id).limit(100).to_a
      @decided = AgentFeedback.assistant_requests.where.not(triage_decision: nil).includes(:user, :task, :triaged_by)
        .order(triaged_at: :desc, id: :desc).limit(DECIDED_LIMIT).to_a
      @projects = Projects::Project.where.not(status: 'archived').order(:name).to_a
      @open_tasks = Projects::Task.unfinished.order(updated_at: :desc).limit(200).pluck(:title, :id)
      @people = User.where(tenant_id: Current.tenant_id, active: true).order(:name, :email).to_a
    end

    def accept
      task = RequestTriage.accept!(request: @assistant_request, user: Current.user, params: decision_params)
      redirect_to projects_requests_path, notice: "Request ##{@assistant_request.id} approved as task ##{task.id}."
    rescue RequestTriage::Error => e
      redirect_to projects_requests_path, alert: e.message
    end

    def merge
      task = RequestTriage.merge!(request: @assistant_request, user: Current.user, params: decision_params)
      redirect_to projects_requests_path, notice: "Request ##{@assistant_request.id} merged into task ##{task.id}."
    rescue RequestTriage::Error => e
      redirect_to projects_requests_path, alert: e.message
    end

    def decline
      RequestTriage.decline!(request: @assistant_request, user: Current.user, params: decision_params)
      redirect_to projects_requests_path, notice: "Request ##{@assistant_request.id} rejected."
    rescue RequestTriage::Error => e
      redirect_to projects_requests_path, alert: e.message
    end

    private

    def require_reviewer
      raise Pundit::NotAuthorizedError unless RequestTriage.reviewer?(Current.user)

      skip_authorization # gate: RequestTriage reviewer
    end

    def load_request
      @assistant_request = AgentFeedback.assistant_requests.find(params[:id])
    end

    def decision_params
      params.fetch(:decision, {}).permit(:title, :project_id, :assignee_id, :priority, :task_id, :reason)
    end
  end
end
