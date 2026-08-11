# frozen_string_literal: true

module People
  class PositionsController < AuthenticatedController
    before_action :set_position, only: [:edit, :update]

    def index
      authorize(:module, :hr_read?)
      @positions = People::Position.ordered.includes(:department)
      @filled = People::Employee.active.group(:position_id).count
    end

    def new
      authorize(:module, :hr_write?)
      @position = People::Position.new
      @departments = People::Department.ordered
    end

    def create
      authorize(:module, :hr_write?)
      @position = People::Position.new(position_params)
      if @position.save
        ActivityLogger.log("position_created", subject: @position)
        redirect_to(people_positions_path, notice: "Position created.")
      else
        @departments = People::Department.ordered
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :hr_write?)
      @departments = People::Department.ordered
    end

    def update
      authorize(:module, :hr_write?)
      if @position.update(position_params)
        ActivityLogger.log("position_updated", subject: @position)
        redirect_to(people_positions_path, notice: "Position updated.")
      else
        @departments = People::Department.ordered
        render(:edit, status: :unprocessable_entity)
      end
    end

    private

    def set_position
      @position = People::Position.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def position_params
      params.require(:position).permit(:name, :department_id, :pay_grade, :description)
    end
  end
end
