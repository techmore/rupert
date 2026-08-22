# frozen_string_literal: true

module Goals
  class KpisController < AuthenticatedController
    before_action :set_kpi, only: %i[show update destroy]

    def index
      authorize(:module, :projects_read?)
      @q = Goals::Kpi.ransack(params[:q])
      @pagy, @kpis = pagy(@q.result.includes(:readings).order(updated_at: :desc), items: 20)
    end

    def show
      authorize(@kpi)
    end

    def new
      authorize(:module, :projects_write?)
      @kpi = Goals::Kpi.new
    end

    def create
      authorize(:module, :projects_write?)
      @kpi = Goals::Kpi.new(kpi_params)
      if @kpi.save
        redirect_to(@kpi, notice: 'KPI created.')
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(@kpi)
    end

    def update
      authorize(@kpi)
      if @kpi.update(kpi_params)
        redirect_to(@kpi, notice: 'KPI updated.')
      else
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(@kpi)
      @kpi.destroy
      redirect_to(kpis_path, notice: 'KPI deleted.')
    end

    # POST /kpis/:id/reading — record a new measurement
    def reading
      authorize(:module, :projects_write?)
      @kpi = Goals::Kpi.find(params[:id])
      @kpi.readings.create!(
        value: params[:value],
        measured_at: params[:measured_at].present? ? Time.zone.parse(params[:measured_at]) : Time.current
      )
      redirect_to(@kpi, notice: 'Reading recorded.')
    rescue ActiveRecord::RecordInvalid => e
      redirect_to(@kpi, alert: e.message)
    end

    private

    def set_kpi
      @kpi = Goals::Kpi.find(params[:id])
    end

    def kpi_params
      params.require(:kpi).permit(:name, :unit, :target_value, :direction)
    end
  end
end
