# frozen_string_literal: true

module Projects
  class ProjectsController < AuthenticatedController
    before_action :set_project, only: %i[show edit update destroy transition]

    def index
      authorize(:module, :projects_read?)
      @q = Projects::Project.ransack(params[:q])
      @pagy, @projects = pagy(@q.result.includes(:tasks).order(updated_at: :desc), items: 15)
    end

    def show
      authorize(@project)
      @tasks = @project.tasks.order(updated_at: :desc)
    end

    def new
      authorize(:module, :projects_write?)
      @project = Projects::Project.new
    end

    def create
      authorize(:module, :projects_write?)
      @project = Projects::Project.new(project_params)
      @project.owner_id = Current.user.id if params[:assign_self]

      if @project.save
        redirect_to(@project, notice: 'Project created.')
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(@project)
    end

    def update
      authorize(@project)
      if @project.update(project_params)
        redirect_to(@project, notice: 'Project updated.')
      else
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(@project)
      @project.destroy
      redirect_to(projects_path, notice: 'Project deleted.')
    end

    # POST /projects/:id/transition?event=start
    def transition
      authorize(@project)
      event = params[:event]
      if %w[start hold complete archive].include?(event) && @project.public_send("may_#{event}?")
        @project.send("#{event}!")
        redirect_to(@project, notice: "Project #{event}d.")
      else
        redirect_to(@project, alert: "Cannot #{event} a #{@project.status} project.")
      end
    end

    private

    def set_project
      @project = Projects::Project.find(params[:id])
    end

    def project_params
      params.require(:project).permit(:name, :description, :due_on)
    end
  end
end
