# frozen_string_literal: true

module People
  # One inbox for everything waiting on a manager: punch fixes, time off, shift trades, timesheets.
  # Approve or Deny inline; the row disappears and the count updates. Nobody decides their own item.
  class ApprovalsController < AuthenticatedController
    before_action :prevent_caching

    def index
      authorize(:module, :approvals_read?)
      @inbox = People::ApprovalInbox.new(Current.user)
      @kind = params[:kind].presence_in(People::ApprovalInbox::KIND_LABELS.keys)
      @items = @kind ? @inbox.items.select { |item| item.kind == @kind } : @inbox.items
    end

    def decide
      authorize(:module, :approvals_read?)
      inbox = People::ApprovalInbox.new(Current.user)
      item = inbox.find(params[:kind], params[:id])
      raise ActiveRecord::RecordNotFound unless item

      approve = params[:decision] == 'approve'
      People::ApprovalDecision.call(item, reviewer: Current.user, approve: approve, note: params[:note])
      ActivityLogger.log("approval_#{approve ? 'approved' : 'denied'}", subject: item.record, details: "#{item.kind} · #{item.employee&.name}#{" · #{params[:note]}" if params[:note].present?}")
      remaining = People::ApprovalInbox.new(Current.user).count
      notice = "#{People::ApprovalInbox::KIND_LABELS[item.kind]} for #{item.employee&.name || 'staff member'} #{approve ? 'approved' : 'denied'}."
      respond_to do |format|
        format.turbo_stream { render turbo_stream: [turbo_stream.remove(item.dom_id), turbo_stream.replace('approvals-count', partial: 'people/approvals/count', locals: { count: remaining }), turbo_stream.replace('approvals-flash', partial: 'people/approvals/flash', locals: { notice: notice })] }
        format.html { redirect_to people_approvals_path(kind: params[:return_kind].presence), notice: notice }
      end
    rescue People::ApprovalDecision::Error, Pundit::NotAuthorizedError => e
      message = e.is_a?(Pundit::NotAuthorizedError) ? 'You cannot decide this item.' : e.message
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.replace('approvals-flash', partial: 'people/approvals/flash', locals: { alert: message }), status: :unprocessable_entity }
        format.html { redirect_to people_approvals_path(kind: params[:return_kind].presence), alert: message }
      end
    end

    private

    def prevent_caching
      response.headers['Cache-Control'] = 'no-store'
    end
  end
end
