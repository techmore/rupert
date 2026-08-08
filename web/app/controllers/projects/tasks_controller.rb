# frozen_string_literal: true

module Projects
  class TasksController < AuthenticatedController
    before_action :set_task, only: [:show, :update, :destroy, :transition]

    def create
      authorize(:module, :projects_write?)
      @project = Projects::Project.find(params[:project_id])
      @task = @project.tasks.new(task_params)
      @task.assignee_id = Current.user.id if params[:assign_self]

      if @task.save
        redirect_to(@project, notice: "Task added.")
      else
        redirect_to(@project, alert: @task.errors.full_messages.join(", "))
      end
    end

    def update
      authorize(@task)
      if @task.update(task_params)
        redirect_back(fallback_location: @task.project, notice: "Task updated.")
      else
        redirect_back(fallback_location: @task.project, alert: @task.errors.full_messages.join(", "))
      end
    end

    def destroy
      authorize(@task)
      project = @task.project
      @task.destroy
      redirect_to(project || projects_path, notice: "Task deleted.")
    end

    # POST /tasks/:id/transition?event=start|finish|block|reopen
    def transition
      authorize(@task)
      event = params[:event]
      if ["start", "finish", "block", "reopen"].include?(event) && @task.public_send("may_#{event}?")
        @task.send("#{event}!")
        redirect_back(fallback_location: @task.project, notice: "Task #{event}ed.")
      else
        redirect_back(fallback_location: @task.project, alert: "Cannot #{event} a #{@task.status} task.")
      end
    end

    private

    def set_task
      @task = Projects::Task.find(params[:id])
    end

    def task_params
      params.require(:task).permit(:title, :description, :priority, :due_on)
    end
  end
end
