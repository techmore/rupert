# frozen_string_literal: true

module Marketing
  # Marketing events (#415): dated promotions kept in the shared work-item table as kind 'marketing_event'
  # (Marketing::WorkKinds). Status changes go through Work::Item#transition!; results live in Marketing::Result.
  class EventsController < BaseController
    KIND = 'marketing_event'
    PAGE = 30

    before_action :set_event, only: %i[show edit update transition]
    rescue_from Work::Item::TransitionRefused, with: :transition_refused

    def index
      authorize(Work::Item.new(kind: KIND), :index?, policy_class: WorkItemPolicy)
      scope = WorkItemPolicy::Scope.new(Current.user, Work::Item.all, kind: KIND).resolve
      scope = scope.where(status: params[:status]) if Work::Registry.fetch(KIND).statuses.include?(params[:status])
      scope = scope.where(source_type: 'Marketing::Campaign', source_id: params[:campaign_id]) if params[:campaign_id].present?
      scope = params[:when] == 'past' ? scope.where(due_on: ...Date.current).order(start_on: :desc, id: :desc) : scope.where(due_on: Date.current..).order(:start_on, :id)
      @page = params[:page].to_i.clamp(1, 10_000)
      @events = scope.includes(:assignee, :source).offset((@page - 1) * PAGE).limit(PAGE + 1).to_a
      @campaigns = Campaign.order(:name).limit(200).to_a
      @locations = location_names(@events)
    end

    def show
      authorize(@event, policy_class: WorkItemPolicy)
      @campaign = @event.source if @event.source_type == 'Marketing::Campaign'
      @offer = Offer.find_by(id: @event.details['offer_id']) if @event.details['offer_id'].present?
      @location = Location.find_by(externalId: @event.details['location_id']) if @event.details['location_id'].present?
      @work = Work::Item.of_kind('campaign_task').where(parent_id: @event.id).includes(:assignee).order(:due_on, :id).limit(101).to_a
      @results = Result.where(work_item_id: @event.id).order(:code, :currency, :order_source, :location_id).limit(201).to_a
      @history = @event.history.reorder(created_at: :desc, id: :desc).limit(25).to_a
      @people = assignable_people
      @can_write = work_policy(@event).update?
    end

    def new
      @event = Work::Item.new(kind: KIND, details: { 'time_zone' => Time.zone.name })
      authorize(@event, :create?, policy_class: WorkItemPolicy)
      if params[:campaign_id].present? && (campaign = Campaign.find_by(id: params[:campaign_id]))
        @event.source = campaign
      end
      load_form
      render(:form)
    end

    def create
      @event = Work::Item.new(kind: KIND)
      authorize(@event, :create?, policy_class: WorkItemPolicy)
      assign(@event)
      if @event.save
        ActivityLogger.log('marketing_event_created', subject: @event)
        redirect_to(marketing_event_path(@event), notice: 'Event saved.')
      else
        load_form
        render(:form, status: :unprocessable_content)
      end
    end

    def edit
      authorize(@event, :update?, policy_class: WorkItemPolicy)
      load_form
      render(:form)
    end

    def update
      authorize(@event, :update?, policy_class: WorkItemPolicy)
      assign(@event)
      if @event.save
        ActivityLogger.log('marketing_event_updated', subject: @event)
        redirect_to(marketing_event_path(@event), notice: 'Event saved.')
      else
        load_form
        render(:form, status: :unprocessable_content)
      end
    end

    def transition
      authorize(@event, :transition?, policy_class: WorkItemPolicy)
      @event.transition!(params[:event].to_s, user: Current.user, note: params[:note])
      redirect_to(marketing_event_path(@event), notice: "Event #{@event.status.humanize.downcase}.")
    end

    private

    def work_policy(record) = WorkItemPolicy.new(Current.user, record)

    def set_event
      @event = Work::Item.of_kind(KIND).find(params[:id])
    end

    def assign(event)
      attrs = params.require(:event).permit(:title, :description, :starts_at, :ends_at, :time_zone, :venue, :channel, :location_id,
        :offer_id, :url, :campaign_id, :assignee_id, :priority)
      event.title = attrs[:title].to_s.squish
      event.description = attrs[:description].to_s.strip.presence
      event.assignee_id = attrs[:assignee_id].presence
      event.priority = attrs[:priority].presence_in(Work::Item::PRIORITIES) || event.priority || 'medium'
      campaign = Campaign.find_by(id: attrs[:campaign_id]) if attrs[:campaign_id].present?
      event.source = campaign
      details = {
        'starts_at' => attrs[:starts_at].to_s.first(16).presence, 'ends_at' => attrs[:ends_at].to_s.first(16).presence,
        'time_zone' => attrs[:time_zone].presence, 'venue' => attrs[:venue].to_s.squish.presence,
        'channel' => attrs[:channel].presence, 'location_id' => attrs[:location_id].presence,
        'offer_id' => attrs[:offer_id].presence&.then { |value| value.to_s.match?(/\A\d+\z/) ? value.to_i : value.to_s },
        'url' => attrs[:url].to_s.strip.presence
      }
      event.details = details.compact
    end

    def load_form
      @campaigns = Campaign.order(:name).limit(200).to_a
      @offers = Offer.order(:code).limit(500).to_a
      @locations = Location.where(active: true).order(:name, :source).limit(200).to_a
      @people = assignable_people
    end

    def assignable_people
      User.where(tenant_id: Current.tenant_id).active.where.not(role: 'employee').ordered.limit(200).to_a
    end

    def location_names(events)
      ids = events.filter_map { |event| event.details['location_id'].presence }.uniq
      ids.empty? ? {} : Location.where(externalId: ids).pluck(:externalId, :name).to_h
    end

    def transition_refused(error)
      redirect_to(marketing_event_path(@event), alert: error.message)
    end
  end
end
