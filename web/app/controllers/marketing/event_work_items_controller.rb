# frozen_string_literal: true

module Marketing
  # Campaign tasks (#415) added to a marketing event: shared work items of kind 'campaign_task' whose parent is the
  # event and whose source is the event's campaign. Status changes go through Work::Item#transition!.
  class EventWorkItemsController < BaseController
    KIND = 'campaign_task'

    before_action :set_event
    rescue_from Work::Item::TransitionRefused, with: :refused

    def create
      item = Work::Item.new(kind: KIND, parent: @event)
      authorize(item, :create?, policy_class: WorkItemPolicy)
      attrs = params.require(:work_item).permit(:title, :assignee_id, :due_on)
      item.assign_attributes(title: attrs[:title].to_s.squish, assignee_id: attrs[:assignee_id].presence, priority: 'medium',
        due_on: parse_date(attrs[:due_on]))
      item.source = @event.source if @event.source_type == 'Marketing::Campaign'
      if item.save
        ActivityLogger.log('campaign_task_created', subject: item)
        redirect_to(marketing_event_path(@event, anchor: 'event-work'), notice: 'Task added.')
      else
        redirect_to(marketing_event_path(@event, anchor: 'event-work'), alert: item.errors.full_messages.to_sentence)
      end
    end

    def transition
      item = Work::Item.of_kind(KIND).where(parent_id: @event.id).find(params[:id])
      authorize(item, :transition?, policy_class: WorkItemPolicy)
      item.transition!(params[:event].to_s, user: Current.user)
      redirect_to(marketing_event_path(@event, anchor: 'event-work'), notice: "Task #{item.status.humanize.downcase}.")
    end

    private

    def set_event
      @event = Work::Item.of_kind('marketing_event').find(params[:event_id])
    end

    def parse_date(text)
      Date.iso8601(text.to_s) if text.present?
    rescue Date::Error
      nil
    end

    def refused(error)
      redirect_to(marketing_event_path(@event, anchor: 'event-work'), alert: error.message)
    end
  end
end
