# frozen_string_literal: true

module Buzz
  # The Buzz module's Team chat page: a small Buzz client with the Rupert
  # identity's channels, their messages and threads, reactions, mentions and
  # unread markers, live updates by polling, and a composer. Reading needs
  # buzz.read and posting (messages and reactions) needs buzz.post; neither is in
  # any role by default, so an administrator grants them on the Permissions screen.
  # Messages are other people's text and are returned as plain strings for the
  # page to show as text. Posts go out as the Rupert identity with the sender's
  # name in front (see Buzz::Chat).
  class ChatController < ::AuthenticatedController
    before_action :require_read
    before_action :require_post, only: %i[create react]
    before_action :load_channel, only: %i[messages create thread members react read]
    before_action -> { response.headers['Cache-Control'] = 'no-store' }, except: :show

    # GET /buzz/chat
    def show
      @state = Buzz::Chat.state
      @can_post = Current.user.can?('buzz.post')
      @can_configure = Current.user.can?('settings.write')
    end

    # GET /buzz/chat/channels — the channels with this person's unread counts.
    def channels
      keep_fresh
      render json: { channels: Buzz::Chat.channels(viewer: Current.user), status: status_json }
    end

    # GET /buzz/chat/members?channel= — who can be mentioned.
    def members
      render json: { members: Buzz::Chat.members(@channel) }
    end

    # GET /buzz/chat/messages(.json) — ?channel=, then ?before=<cursor> for scrollback, ?after=<cursor> for new messages.
    def messages
      before = Buzz::Message.parse_cursor(params[:before]) if params[:before].present?
      after = Buzz::Message.parse_cursor(params[:after]) if params[:after].present?
      return render json: { error: 'Bad cursor.' }, status: :unprocessable_entity if (params[:before].present? && before.nil?) || (params[:after].present? && after.nil?)

      keep_fresh unless before
      page = Buzz::Chat.page(before: before, after: after, viewer: Current.user, channel: @channel)
      render json: page.merge(status: status_json)
    end

    # GET /buzz/chat/threads/:id?channel= — a message with its replies (?refresh=1 asks the relay for older replies).
    def thread
      found = Buzz::Chat.thread(params[:id], channel: @channel, viewer: Current.user, refresh: params[:refresh].present?)
      return render json: { error: 'That thread is not available.' }, status: :not_found unless found

      render json: found.merge(status: status_json)
    end

    # POST /buzz/chat/messages { channel:, message: "...", reply_to: <message id>, mentions: [pubkey, ...] }
    def create
      Buzz::Chat.post!(user: Current.user, text: params[:message], channel: @channel, reply_to: params[:reply_to].presence,
        mentions: Array(params[:mentions]).grep(String))
      render json: { ok: true }, status: :created
    rescue Buzz::Chat::RateLimited
      render json: { error: 'You are posting quickly. Wait a moment and try again.' }, status: :too_many_requests
    rescue Buzz::Chat::Error => e
      render json: { error: e.message }, status: (e.is_a?(Buzz::Chat::PostFailed) ? :bad_gateway : :unprocessable_entity)
    end

    # POST /buzz/chat/reactions { channel:, message: <id>, emoji: "👍" } — adds the reaction or takes it back.
    def react
      result = Buzz::Chat.react!(user: Current.user, channel: @channel, message: params[:message], emoji: params[:emoji])
      render json: { ok: true, result: result }
    rescue Buzz::Chat::RateLimited
      render json: { error: 'You are reacting quickly. Wait a moment and try again.' }, status: :too_many_requests
    rescue Buzz::Chat::Error => e
      render json: { error: e.message }, status: (e.is_a?(Buzz::Chat::PostFailed) ? :bad_gateway : :unprocessable_entity)
    end

    # POST /buzz/chat/read { channel: } — this person has seen the channel up to now.
    def read
      Buzz::Chat.mark_read!(Current.user, @channel)
      head :no_content
    end

    private

    def load_channel
      @channel = Buzz::Chat.resolve_channel(params[:channel])
      return if @channel
      return render json: { messages: [], has_more: false, older_failed: false, status: status_json } if action_name == 'messages' && !Buzz::Chat.ready?

      render json: { error: 'Rupert is not in that channel.' }, status: :unprocessable_entity
    end

    def require_read
      return head :forbidden if Current.user.employee? || !Current.user.can?('buzz.read') || Current.tenant_id != Current.user.tenant_id

      authorize(:module, :dashboard_read?)
    end

    def require_post
      head :forbidden unless Current.user.can?('buzz.post')
    end

    # The first look fills the copy right away; after that a background job brings
    # it up to date, at most every few seconds however many pages are open.
    def keep_fresh
      return unless Buzz::Chat.ready?
      return unless Buzz::ChatState.claim_attempt!

      if Buzz::Chat.empty_cache?
        Buzz::Chat.sync!
      else
        Buzz::SyncJob.perform_later(Current.tenant_id)
      end
    end

    def status_json
      status = Buzz::Chat.status
      { state: status[:state], synced_at: status[:synced_at]&.iso8601, error: status[:error], can_post: Current.user.can?('buzz.post'),
        post_max: Buzz::Chat::POST_MAX }
    end
  end
end
