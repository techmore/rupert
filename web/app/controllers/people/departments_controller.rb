# frozen_string_literal: true

module People
  class DepartmentsController < AuthenticatedController
    before_action :set_department, only: [:edit, :update]

    def index
      authorize(:module, :hr_read?)
      @departments = People::Department.ordered.includes(:manager, :positions)
      @headcount = People::Employee.active.group(:department_id).count
    end

    def new
      authorize(:module, :hr_write?)
      @department = People::Department.new
      @managers = People::Employee.active.ordered
    end

    def create
      authorize(:module, :hr_write?)
      @department = People::Department.new(department_params)
      if @department.save
        ActivityLogger.log("department_created", subject: @department)
        redirect_to(people_departments_path, notice: "Department created.")
      else
        @managers = People::Employee.active.ordered
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :hr_write?)
      @managers = People::Employee.active.ordered
    end

    def update
      authorize(:module, :hr_write?)
      if @department.update(department_params)
        ActivityLogger.log("department_updated", subject: @department)
        redirect_to(people_departments_path, notice: "Department updated.")
      else
        @managers = People::Employee.active.ordered
        render(:edit, status: :unprocessable_entity)
      end
    end

    private

    def set_department
      @department = People::Department.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def department_params
      params.require(:department).permit(:name, :code, :description, :manager_id)
    end
  end
end
