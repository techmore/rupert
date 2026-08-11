# frozen_string_literal: true

module People
  # Leave & PTO: employees request time off, managers approve or deny, and
  # balances track the annual allowance vs used hours.
  class LeaveRequestsController < AuthenticatedController
    before_action :set_leave_request, only: [:show, :destroy, :approve, :deny, :cancel]

    def index
      authorize(:module, :leave_read?)
      @status = params[:status].presence || "all"
      @requests = People::LeaveRequest.by_status(@status).recent(200).includes(:employee)
      @by_employee = People::LeaveRequest.pending.group(:employee_id).count
      @balances = People::LeaveBalance.for_year(Date.current.year).ordered.includes(:employee)
    end

    def show
      authorize(@leave_request)
      @balance = @leave_request.employee.leave_balance(@leave_request.leave_type, Date.current.year)
    end

    def new
      authorize(:module, :leave_write?)
      @leave_request = People::LeaveRequest.new(starts_on: Date.today, ends_on: Date.today)
      @employees = People::Employee.active.ordered
    end

    def create
      authorize(:module, :leave_write?)
      @leave_request = People::LeaveRequest.new(leave_request_params)
      if @leave_request.save
        ActivityLogger.log("leave_requested", subject: @leave_request, details: "#{@leave_request.leave_type} · #{@leave_request.duration_label}")
        redirect_to(people_leave_request_path(@leave_request), notice: "Leave request created.")
      else
        @employees = People::Employee.active.ordered
        render(:new, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :leave_write?)
      return redirect_to(people_leave_request_path(@leave_request), alert: "Cancelling is safer than deleting a request.") unless @leave_request.cancelled?

      @leave_request.destroy
      redirect_to(people_leave_requests_path, notice: "Leave request removed.")
    end

    def approve
      authorize(:module, :leave_write?)
      @leave_request.approve! if @leave_request.may_approve?
      @leave_request.update!(reviewed_by: Current.user.id, reviewed_at: Time.current)
      apply_balance(@leave_request) if @leave_request.approved?
      ActivityLogger.log("leave_approved", subject: @leave_request)
      redirect_to(people_leave_request_path(@leave_request), notice: "Leave approved.")
    end

    def deny
      authorize(:module, :leave_write?)
      @leave_request.deny! if @leave_request.may_deny?
      @leave_request.update!(reviewed_by: Current.user.id, reviewed_at: Time.current)
      ActivityLogger.log("leave_denied", subject: @leave_request)
      redirect_to(people_leave_request_path(@leave_request), notice: "Leave denied.")
    end

    def cancel
      authorize(:module, :leave_write?)
      if @leave_request.may_cancel?
        @leave_request.cancel!
        revert_balance(@leave_request)
      end
      ActivityLogger.log("leave_cancelled", subject: @leave_request)
      redirect_to(people_leave_request_path(@leave_request), notice: "Leave request cancelled.")
    end

    private

    def set_leave_request
      @leave_request = People::LeaveRequest.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def leave_request_params
      params.require(:leave_request).permit(:employee_id, :leave_type, :starts_on, :ends_on, :hours, :reason)
    end

    # Approval consumes the employee's balance for the requested period.
    def apply_balance(request)
      return if request.leave_type == "unpaid"

      balance = request.employee.leave_balance(request.leave_type, request.starts_on.year)
      used = request.hours.presence || request.days * 8
      balance.used_hours = (balance.used_hours || 0) + used
      balance.save!
    end

    # Cancelling an approved request gives the hours back.
    def revert_balance(request)
      return if request.leave_type == "unpaid"

      balance = request.employee.leave_balance(request.leave_type, request.starts_on.year)
      used = request.hours.presence || request.days * 8
      balance.used_hours = [balance.used_hours.to_f - used, 0].max
      balance.save!
    end
  end
end
