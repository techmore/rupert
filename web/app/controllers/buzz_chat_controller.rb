# frozen_string_literal: true

# The Team chat tab on the Buzz page: a small Buzz client with the agent's
# channels, their messages and threads, reactions, mentions and unread markers,
# live updates by polling, and a composer. Reading needs buzz.read and posting
# (messages and reactions) needs buzz.post (administrators by default;
# delegable on the Permissions screen).
# Messages are other people's text and are returned as plain strings for the
# page to show as text. Posts go out as the Rupert agent with the sender's name
# in front, so the relay never sees a per-person key (see BuzzChat).
class BuzzChatController < AuthenticatedController
  before_action :require_read
  before_action :require_post, only: %i[create react]
  before_action :load_channel, only: %i[messages create thread members react read]
  before_action -> { response.headers['Cache-Control'] = 'no-store' }, except: :show

  # GET /buzz/chat
  def show
    @state = BuzzChat.state
    @can_post = Current.user.can?('buzz.post')
    @can_configure = Current.user.can?('settings.write')
  end

  # GET /buzz/chat/channels — the channels with this person's unread counts.
  def channels
    keep_fresh
    render json: { channels: BuzzChat.channels(viewer: Current.user), status: status_json }
  end

  # GET /buzz/chat/members?channel= — who can be mentioned.
  def members
    render json: { members: BuzzChat.members(@channel) }
  end

  # GET /buzz/chat/messages(.json) — ?channel=, then ?before=<cursor> for scrollback, ?after=<cursor> for new messages.
  def messages
    before = BuzzMessage.parse_cursor(params[:before]) if params[:before].present?
    after = BuzzMessage.parse_cursor(params[:after]) if params[:after].present?
    return render json: { error: 'Bad cursor.' }, status: :unprocessable_entity if (params[:before].present? && before.nil?) || (params[:after].present? && after.nil?)

    keep_fresh unless before
    page = BuzzChat.page(before: before, after: after, viewer: Current.user, channel: @channel)
    render json: page.merge(status: status_json)
  end

  # GET /buzz/chat/threads/:id?channel= — a message with its replies (?refresh=1 asks the relay for older replies).
  def thread
    found = BuzzChat.thread(params[:id], channel: @channel, viewer: Current.user, refresh: params[:refresh].present?)
    return render json: { error: 'That thread is not available.' }, status: :not_found unless found

    render json: found.merge(status: status_json)
  end

  # POST /buzz/chat/messages { channel:, message: "...", reply_to: <message id>, mentions: [pubkey, ...] }
  def create
    BuzzChat.post!(user: Current.user, text: params[:message], channel: @channel, reply_to: params[:reply_to].presence,
      mentions: Array(params[:mentions]).grep(String))
    render json: { ok: true }, status: :created
  rescue BuzzChat::RateLimited
    render json: { error: 'You are posting quickly. Wait a moment and try again.' }, status: :too_many_requests
  rescue BuzzChat::Error => e
    render json: { error: e.message }, status: (e.is_a?(BuzzChat::PostFailed) ? :bad_gateway : :unprocessable_entity)
  end

  # POST /buzz/chat/reactions { channel:, message: <id>, emoji: "👍" } — adds the reaction or takes it back.
  def react
    result = BuzzChat.react!(user: Current.user, channel: @channel, message: params[:message], emoji: params[:emoji])
    render json: { ok: true, result: result }
  rescue BuzzChat::RateLimited
    render json: { error: 'You are reacting quickly. Wait a moment and try again.' }, status: :too_many_requests
  rescue BuzzChat::Error => e
    render json: { error: e.message }, status: (e.is_a?(BuzzChat::PostFailed) ? :bad_gateway : :unprocessable_entity)
  end

  # POST /buzz/chat/read { channel: } — this person has seen the channel up to now.
  def read
    BuzzChat.mark_read!(Current.user, @channel)
    head :no_content
  end

  private

  def load_channel
    @channel = BuzzChat.resolve_channel(params[:channel])
    return if @channel
    return render json: { messages: [], has_more: false, older_failed: false, status: status_json } if action_name == 'messages' && !BuzzChat.ready?

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
    return unless BuzzChat.ready?
    return unless BuzzChatState.claim_attempt!

    if BuzzChat.empty_cache?
      BuzzChat.sync!
    else
      BuzzChatSyncJob.perform_later(Current.tenant_id)
    end
  end

  def status_json
    status = BuzzChat.status
    { state: status[:state], synced_at: status[:synced_at]&.iso8601, error: status[:error], can_post: Current.user.can?('buzz.post'),
      post_max: BuzzChat::POST_MAX }
  end
end
