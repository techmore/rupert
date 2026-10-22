# frozen_string_literal: true

require 'digest'
require 'json'

# The Team chat tab on the Buzz page, a small Buzz client: the channels the Rupert
# agent belongs to (kind 39002 member lists and 39000 metadata), their recent
# messages (kept as a short-lived copy so the page is quick and still works while
# the relay is briefly out of reach), threads (NIP-10 e tags), reactions (kind 7),
# the names of the people involved, unread markers, and posting.
#
# Everything that comes from the relay is untrusted text from other people. It is
# checked (id, signature, channel), cleaned, capped and stored as text; the page
# only ever shows it as text. Nothing linked from a message is fetched.
#
# Posting identity (v1): messages go out signed by the @rupert agent key with a
# visible prefix, "Sam via Rupert: ...", and a `client` tag. Rupert holds no
# per-person Nostr keys. Because of that the relay, the Buzz apps and the intake
# allow-list see the AGENT as the sender, never the person, so a message posted
# here can never mark work "ready for development" (FeedbackIntake refuses the
# agent's own key as a sender). Neither the private key nor any nsec is ever
# logged or shown.
class BuzzChat
  class Error < StandardError; end
  class NotReady < Error; end
  class Invalid < Error; end
  class RateLimited < Error; end
  class PostFailed < Error; end

  KINDS = [9, 40_002].freeze # stream message, stream message v2
  EDIT_KIND = 40_003
  DELETE_KINDS = [5, 9005].freeze # NIP-09 deletion, Buzz moderator/author delete
  REACTION_KIND = 7
  MAX_CHANNELS = 20
  REACTION_TARGETS = 200 # newest messages whose reactions each sync re-reads
  CONTROL_WINDOW = 2.days # how far back each sync re-reads edits and deletions
  THREAD_MAX = 200
  MENTION_MAX = 10
  PAGE = 40
  SYNC_LIMIT = 100
  CATCH_UP_LIMIT = 500 # the relay's cap per filter
  CATCH_UP_OVERLAP = 120 # seconds re-read behind the newest cached message
  OLDER_FETCH = 100
  RETENTION = 30.days
  POST_MAX = 1500
  POST_LIMITS = { 1.minute => 6, 1.hour => 60 }.freeze
  REACTION_LIMIT = 20 # per person per minute
  CLIENT_TAG = 'rupert-chat'
  VIA = ' via Rupert: '
  NSEC = /nsec1[02-9ac-hj-np-z]{20,}/i
  CONTROL = /[^\P{Cc}\n\t]/
  HEX64 = /\A\h{64}\z/
  PROFILE_BATCH = 50
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  class << self
    # :unconfigured (no relay or no agent key), :no_channel, or :ready.
    def state
      return :unconfigured unless BuzzAgent.configured?

      BuzzAgent.channel_id.present? ? :ready : :no_channel
    end

    def ready? = state == :ready

    def channel = BuzzAgent.channel_id

    def agent_pubkey
      BuzzAgent.public_key_hex.presence
    rescue StandardError
      nil
    end


    # --- channels ---

    # The channels to read: what the relay says the agent belongs to, or just the
    # configured one before the first look.
    def channel_ids
      ids = BuzzChannel.active.limit(MAX_CHANNELS).pluck(:channel_id)
      ids = [channel] if ids.empty? && channel.present?
      ids
    end

    # The channel id to use for a request: the given one when the agent belongs to
    # it, the configured one when none is given, otherwise nil.
    def resolve_channel(id)
      wanted = id.to_s.strip.presence || channel
      channel_ids.include?(wanted) ? wanted : nil
    end

    # Channels for the sidebar, with each person's unread count. A channel the
    # person has never opened starts out read (the first look is not a flood).
    def channels(viewer:)
      rows = BuzzChannel.active.limit(MAX_CHANNELS).to_a
      ids = rows.map(&:channel_id)
      reads = read_marks(viewer, ids)
      list = rows.map { |row| present_channel(row, reads[row.channel_id], viewer) }
      list = [fallback_channel(viewer)] if list.empty? && channel.present?
      list.sort_by { |c| [c[:id] == channel ? 0 : 1, c[:name].downcase] }
    end

    # The people who can be mentioned in a channel (its members), the agent first.
    def members(channel_id)
      row = BuzzChannel.find_by(channel_id: channel_id)
      return [] unless row

      pairs = row.member_list
      profiles = BuzzProfile.where(pubkey: pairs.map(&:first)).index_by(&:pubkey)
      agent = agent_pubkey
      list = pairs.map do |pubkey, role|
        is_agent = pubkey == agent
        name = profiles[pubkey]&.label || (is_agent ? BuzzAgentPrompt::NAME : nil)
        { pubkey: pubkey, name: name || short_npub(pubkey), named: name.present?, role: role.to_s, agent: is_agent, key: short_npub(pubkey) }
      end
      list.sort_by { |m| [m[:agent] ? 0 : 1, m[:name].downcase] }
    end

    # Records that this person has seen everything in the channel so far.
    def mark_read!(viewer, channel_id)
      newest = BuzzMessage.in_channel(channel_id).maximum(:posted_at) || Time.now.to_i
      mark = BuzzChatRead.find_or_initialize_by(user_id: viewer.id, channel: channel_id)
      mark.update!(read_at: [mark.read_at.to_i, newest].max)
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    # --- reading ---

    # Asks the relay for what is new in every channel (or the latest page on first
    # use) and stores it, along with edits, deletions and reactions. Returns the
    # number of new messages, or nil when the relay could not be read; the reason
    # is kept for the page. Never raises.
    def sync!
      return unless ready?

      refresh_channels! if BuzzChannel.stale?
      ids = channel_ids
      events = BuzzRelayClient.query(sync_filters(ids))
      stored = ingest_all(events, ids)
      refresh_profiles
      BuzzChatState.succeeded!
      stored
    rescue BuzzRelayClient::Error => e
      BuzzChatState.failed!(e.message)
      nil
    rescue StandardError => e
      Rails.logger.error("[BuzzChat] sync: #{e.class}")
      BuzzChatState.failed!('Rupert could not read the channel just now')
      nil
    end

    # Messages of one channel for the page, oldest first, as { messages:, has_more: }.
    # The timeline holds top-level messages only; replies live in their thread.
    #   before: cursor  -> a page of earlier messages (asks the relay when the copy runs out)
    #   after:  cursor  -> every message (replies too) newer than the cursor
    #   neither         -> the latest page
    def page(before: nil, after: nil, limit: PAGE, viewer: nil, channel: self.channel)
      limit = limit.to_i.clamp(1, 100)
      scope = messages_scope(channel)
      rows, has_more, older_failed =
        if after
          [scope.newer_than(after).oldest_first.limit(limit * 3).to_a, false, false]
        elsif before
          older_page(channel, before, limit)
        else
          latest_page(scope, limit)
        end
      { messages: present(rows, viewer: viewer), has_more: has_more, older_failed: older_failed }
    end

    # One thread: the root message and its replies, oldest first. Asks the relay for
    # the replies when the thread is opened (older replies may not be copied yet).
    def thread(root_id, channel:, viewer: nil, refresh: false)
      root = messages_scope(channel).find_by(event_id: root_id.to_s)
      return unless root

      root = messages_scope(channel).find_by(event_id: root.thread_root) || root if root.thread_root.present?
      fetch_thread(root.event_id) if refresh
      replies = messages_scope(channel).where(thread_root: root.event_id).oldest_first.limit(THREAD_MAX).to_a
      shown = present([root] + replies, viewer: viewer)
      { root: shown.first, replies: shown.drop(1) }
    end

    def empty_cache? = BuzzMessage.none?

    # What the page shows about the connection.
    def status
      row = BuzzChatState.current
      { state: state, synced_at: row.last_success_at, error: row.last_error, channel: channel.presence }
    end

    # Cached messages as plain hashes for the browser. Text is returned raw;
    # the page renders it as text (textContent), never as HTML.
    def present(rows, viewer: nil)
      pubkeys = rows.map(&:pubkey).uniq
      names = BuzzProfile.where(pubkey: pubkeys).index_by(&:pubkey)
      agent = agent_pubkey
      extras = thread_extras(rows)
      reactions = reaction_summaries(rows.map(&:event_id), agent)
      rows.map { |row| present_one(row, names[row.pubkey], agent, viewer, extras[row.event_id], reactions[row.event_id] || []) }
    end

    # --- writing ---

    # Posts as the Rupert agent. reply_to is the id of a message to answer in its
    # thread; mentions are member pubkeys whose @name appears in the text. Raises
    # NotReady, Invalid, RateLimited or PostFailed with a message that is safe to show.
    def post!(user:, text:, channel: self.channel, reply_to: nil, mentions: [])
      raise NotReady, 'Team chat is not set up yet.' unless ready?

      channel = resolve_channel(channel) || raise(Invalid, 'Rupert is not in that channel.')
      clean = clean_post(text)
      enforce_rate_limit!(user)
      thread_ref = thread_reference(channel, reply_to)
      tags = [['client', CLIENT_TAG]] + thread_tag_list(thread_ref) + mention_tag_list(channel, clean, mentions)
      event = BuzzAgent.build_event(content: "#{sender_name(user)}#{VIA}#{clean}", channel: channel, tags: tags)
      ok, reason = BuzzRelayClient.publish(event)
      unless ok
        Rails.logger.warn("[BuzzChat] post failed for user #{user.id}: #{reason.to_s[0, 120]}")
        raise PostFailed, 'Rupert could not reach Buzz, so your message was not sent. Try again in a moment.'
      end

      row = store_posted(event, user, thread_ref)
      ActivityLogger.log('buzz_chat_post', details: "event=#{event.id[0, 12]} chars=#{clean.length}#{' reply' if thread_ref}")
      row
    end

    # Adds the agent's reaction to a message, or takes it back when it is already
    # there. Reactions are signed by the agent like every other post (Rupert holds
    # no per-person keys), so they show as Rupert's. Returns :added or :removed.
    def react!(user:, channel:, message:, emoji:)
      raise NotReady, 'Team chat is not set up yet.' unless ready?

      channel = resolve_channel(channel) || raise(Invalid, 'Rupert is not in that channel.')
      emoji = emoji.to_s.strip
      raise Invalid, 'Pick one of the offered reactions.' unless BuzzReaction::QUICK.include?(emoji)

      target = messages_scope(channel).find_by(event_id: message.to_s) || raise(Invalid, 'That message is not available any more.')
      existing = BuzzReaction.find_by(target_id: target.event_id, pubkey: agent_pubkey, emoji: emoji)
      return take_back_reaction(existing) if existing

      enforce_reaction_limit!(user)
      event = BuzzAgent.build_event(kind: REACTION_KIND, content: emoji, tags: [['e', target.event_id]])
      publish_or_fail!(event, user, 'react')
      store_reaction(event, target, user)
      :added
    end

    # Deletes copies past the retention window. Run per tenant.
    def purge!(now: Time.current)
      cutoff = (now - RETENTION).to_i
      removed = BuzzMessage.where(posted_at: ...cutoff).delete_all
      BuzzReaction.where(target_id: BuzzReaction.select(:target_id).where.not(target_id: BuzzMessage.select(:event_id))).delete_all
      BuzzChatRead.where(updated_at: ...(now - 90.days)).delete_all
      BuzzProfile.where(fetched_at: ...(now - 90.days)).delete_all
      removed
    end

    def short_npub(pubkey)
      npub = Nostr::PublicKey.new(pubkey).to_bech32
      "#{npub[0, 12]}…#{npub[-4..]}"
    rescue StandardError
      "#{pubkey.to_s[0, 8]}…"
    end

    private

    def messages_scope(channel_id) = BuzzMessage.in_channel(channel_id)

    # --- sync helpers ---

    def sync_filters(ids)
      since = (Time.now - CONTROL_WINDOW).to_i
      filters = ids.map do |id|
        newest = messages_scope(id).maximum(:posted_at)
        filter = { kinds: KINDS, '#h': [id] }
        newest ? filter.merge(since: [newest - CATCH_UP_OVERLAP, 0].max, limit: CATCH_UP_LIMIT) : filter.merge(limit: SYNC_LIMIT)
      end
      filters << { kinds: [EDIT_KIND], '#h': ids, since: since, limit: 200 }
      filters << { kinds: DELETE_KINDS, '#h': ids, since: since, limit: 200 }
      targets = reaction_target_ids(ids)
      filters << { kinds: [REACTION_KIND], '#e': targets, limit: CATCH_UP_LIMIT } if targets.any?
      filters
    end

    def reaction_target_ids(ids)
      BuzzMessage.where(channel: ids).order(posted_at: :desc).limit(REACTION_TARGETS).pluck(:event_id)
    end

    # Sorts one relay answer by kind and applies each part; returns the number of
    # new messages.
    def ingest_all(events, ids)
      events = Array(events).grep(Hash)
      by_kind = events.group_by { |e| e['kind'] }
      messages = by_kind.values_at(*KINDS).compact.flatten
      drop_gaps(messages, ids)
      stored = ingest(messages, ids)
      apply_edits(by_kind[EDIT_KIND], ids)
      apply_deletions(by_kind.values_at(*DELETE_KINDS).compact.flatten, ids)
      sync_reactions(by_kind[REACTION_KIND], ids)
      stored
    end

    # More new messages arrived in a channel than one request returns: the copy is
    # no longer contiguous there, so forget what is older than the newest batch.
    def drop_gaps(events, ids)
      events.group_by { |e| channel_of(e, ids) }.each do |id, list|
        next unless id && list.size >= CATCH_UP_LIMIT && messages_scope(id).exists?

        oldest = list.filter_map { |e| e['created_at'].to_i }.min
        messages_scope(id).where(posted_at: ...oldest).delete_all if oldest
      end
    end

    def channel_of(event, ids)
      tags = event['tags']
      return unless tags.is_a?(Array)

      tags.find { |t| t.is_a?(Array) && t[0] == 'h' && ids.include?(t[1]) }&.at(1)
    end

    def fetch_older(channel_id, cursor)
      return false unless ready?

      events = BuzzRelayClient.query([{ kinds: KINDS, '#h': [channel_id], until: cursor[0], limit: OLDER_FETCH }])
      ingest(events, channel_ids)
      refresh_profiles
      true
    rescue BuzzRelayClient::Error
      false
    end

    # The replies of a thread, for threads older than the sync window.
    def fetch_thread(root_id)
      events = BuzzRelayClient.query([{ kinds: KINDS, '#e': [root_id], limit: THREAD_MAX }])
      ingest(events, channel_ids)
      refresh_profiles
    rescue BuzzRelayClient::Error
      nil
    end

    def latest_page(scope, limit)
      rows = scope.top_level.newest_first.limit(limit + 1).to_a
      [rows.first(limit).reverse, rows.size > limit, false]
    end

    def older_page(channel_id, cursor, limit)
      failed = false
      scope = messages_scope(channel_id).top_level
      failed = !fetch_older(channel_id, cursor) if scope.older_than(cursor).limit(limit + 1).count <= limit
      rows = scope.older_than(cursor).newest_first.limit(limit + 1).to_a
      [rows.first(limit).reverse, rows.size > limit || failed, failed]
    end

    # Validates and stores relay messages; returns how many were new.
    def ingest(events, ids)
      now = Time.current
      rows = Array(events).filter_map { |event| row_for(event, now, ids) }
      return 0 if rows.empty?

      before = BuzzMessage.count
      BuzzMessage.insert_all(rows, unique_by: :idx_buzz_messages_event)
      BuzzMessage.count - before
    end

    def row_for(event, now, ids)
      return unless valid_event?(event, KINDS)

      tags = event['tags']
      channel_id = channel_of(event, ids)
      return unless channel_id

      root, parent = thread_of(tags)
      {
        tenant_id: Current.tenant_id, event_id: event['id'], pubkey: event['pubkey'], kind: event['kind'], channel: channel_id,
        content: clean_incoming(event['content']), reply_to: parent, thread_root: root, client: client_tag(tags),
        posted_at: event['created_at'], created_at: now, updated_at: now
      }
    end

    def valid_event?(event, kinds)
      return false unless event.is_a?(Hash)
      return false unless event['id'].to_s.match?(HEX64) && event['pubkey'].to_s.match?(HEX64) && event['sig'].to_s.match?(/\A\h{128}\z/)
      return false unless kinds.include?(event['kind']) && event['content'].is_a?(String) && event['tags'].is_a?(Array)
      return false unless event['tags'].all? { |t| t.is_a?(Array) && t.all?(String) }
      return false unless event['created_at'].is_a?(Integer) && event['created_at'].between?(1_500_000_000, Time.now.to_i + 86_400)

      signed_correctly?(event)
    end

    def signed_correctly?(event)
      digest = Digest::SHA256.hexdigest(JSON.generate([0, event['pubkey'], event['created_at'], event['kind'], event['tags'], event['content']]))
      return false unless digest == event['id']

      Nostr::Event.new(id: event['id'], pubkey: event['pubkey'], created_at: event['created_at'], kind: event['kind'],
        tags: event['tags'], content: event['content'], sig: event['sig']).verify_signature
    rescue StandardError
      false
    end

    def clean_incoming(text)
      text.to_s.scrub('').gsub(CONTROL, '').gsub(NSEC, '[private key removed]').strip.first(BuzzMessage::CONTENT_MAX)
    end

    # [root, parent] from the NIP-10 markers, the way Buzz resolves them: a reply
    # names its parent (and the root when it is nested); a lone root marker or no
    # markers means a top-level message. Unmarked e tags are ignored.
    def thread_of(tags)
      root = reply = nil
      tags.each do |tag|
        next unless tag[0] == 'e' && tag.size >= 4 && tag[1].to_s.match?(HEX64)

        root = tag[1] if tag[3] == 'root'
        reply = tag[1] if tag[3] == 'reply'
      end
      return [nil, nil] unless reply

      [root || reply, reply]
    end

    def client_tag(tags)
      value = tags.find { |t| t[0] == 'client' }&.at(1).to_s
      value.match?(/\A[a-z0-9._-]{1,40}\z/) ? value : nil
    end

    # --- edits, deletions, reactions ---

    # An edit replaces the text of the author's own message. Only the newest edit
    # per message counts, and only from the message's own author.
    def apply_edits(events, ids)
      edits = Array(events).select { |e| valid_event?(e, [EDIT_KIND]) }.filter_map do |edit|
        target = edit['tags'].find { |t| t[0] == 'e' && t[1].to_s.match?(HEX64) }&.at(1)
        channel_id = channel_of(edit, ids)
        row = messages_scope(channel_id).find_by(event_id: target, pubkey: edit['pubkey']) if target && channel_id
        [row, edit] if row && edit['created_at'] >= row.posted_at
      end
      edits.group_by { |row, _| row.id }.each_value do |list|
        row, edit = list.max_by { |_, e| e['created_at'] }
        row.update_columns(content: clean_incoming(edit['content']), edited: true, updated_at: Time.current)
      end
    end

    # A person may delete their own message (kind 5); the relay vouches for
    # moderators' deletes (kind 9005). Reactions to a removed message go with it.
    def apply_deletions(events, ids)
      events.each do |event|
        next unless valid_event?(event, DELETE_KINDS)

        targets = event['tags'].select { |t| t[0] == 'e' && t[1].to_s.match?(HEX64) }.map { |t| t[1] }
        next if targets.empty?

        scope = BuzzMessage.where(event_id: targets, channel: ids)
        scope = scope.where(pubkey: event['pubkey']) if event['kind'] == 5
        gone = scope.pluck(:event_id)
        BuzzMessage.where(event_id: gone).delete_all
        BuzzReaction.where(target_id: gone).delete_all
      end
    end

    # The relay's answer is the whole truth for the messages it was asked about:
    # reactions it no longer returns (taken back) are forgotten here too.
    def sync_reactions(events, ids)
      targets = reaction_target_ids(ids)
      return if targets.empty?

      channels = BuzzMessage.where(event_id: targets).pluck(:event_id, :channel).to_h
      now = Time.current
      rows = Array(events).filter_map { |event| reaction_row(event, channels, now) }.uniq { |r| r[:event_id] }
      BuzzReaction.where(target_id: targets).where.not(event_id: rows.pluck(:event_id)).delete_all
      BuzzReaction.insert_all(rows, unique_by: :idx_buzz_reactions_event) if rows.any?
    end

    def reaction_row(event, channels, now)
      return unless valid_event?(event, [REACTION_KIND])

      target = event['tags'].find { |t| t[0] == 'e' && t[1].to_s.match?(HEX64) }&.at(1)
      emoji = clean_reaction(event['content'])
      return unless target && channels[target] && emoji

      { tenant_id: Current.tenant_id, event_id: event['id'], target_id: target, channel: channels[target], pubkey: event['pubkey'],
        emoji: emoji, posted_at: event['created_at'], created_at: now, updated_at: now }
    end

    # An empty reaction is NIP-25's "+" (a like).
    def clean_reaction(text)
      value = text.to_s.scrub('').gsub(CONTROL, '').strip
      value = '👍' if value.empty? || value == '+'
      value.length <= BuzzReaction::EMOJI_MAX ? value : nil
    end

    def reaction_summaries(ids, agent)
      return {} if ids.empty?

      rows = BuzzReaction.where(target_id: ids).order(:posted_at, :id).to_a
      names = BuzzProfile.where(pubkey: rows.map(&:pubkey).uniq).index_by(&:pubkey)
      rows.group_by(&:target_id).transform_values do |list|
        list.group_by(&:emoji).map do |emoji, group|
          { emoji: emoji, count: group.size, mine: group.any? { |r| r.pubkey == agent },
            by: group.first(8).map { |r| reactor_name(r.pubkey, names[r.pubkey], agent) } }
        end
      end
    end

    def reactor_name(pubkey, profile, agent)
      return 'Rupert (an administrator)' if pubkey == agent

      profile&.label || short_npub(pubkey)
    end

    def take_back_reaction(reaction)
      event = BuzzAgent.build_event(kind: 5, content: '', tags: [['e', reaction.event_id]])
      ok, reason = BuzzRelayClient.publish(event)
      unless ok
        Rails.logger.warn("[BuzzChat] reaction removal failed: #{reason.to_s[0, 120]}")
        raise PostFailed, 'Rupert could not reach Buzz, so the reaction was not changed. Try again in a moment.'
      end

      reaction.destroy
      :removed
    end

    def publish_or_fail!(event, user, what)
      ok, reason = BuzzRelayClient.publish(event)
      return if ok

      Rails.logger.warn("[BuzzChat] #{what} failed for user #{user.id}: #{reason.to_s[0, 120]}")
      raise PostFailed, 'Rupert could not reach Buzz, so the reaction was not sent. Try again in a moment.'
    end

    def store_reaction(event, target, user)
      BuzzReaction.create!(event_id: event.id, target_id: target.event_id, channel: target.channel, pubkey: event.pubkey.to_s,
        emoji: event.content, rupert_user_id: user.id, posted_at: event.created_at)
    rescue ActiveRecord::RecordNotUnique
      BuzzReaction.find_by(event_id: event.id)
    end

    def enforce_reaction_limit!(user)
      return if BuzzReaction.where(rupert_user_id: user.id).where(created_at: 1.minute.ago..).count < REACTION_LIMIT

      raise RateLimited, 'You are reacting quickly. Wait a moment and try again.'
    end

    # --- channels ---

    # One relay call for the member lists that include the agent and the channels'
    # metadata; keeps one row per channel the agent belongs to.
    def refresh_channels!
      agent = agent_pubkey
      events = BuzzRelayClient.query([{ kinds: [39_002], '#p': [agent], limit: 100 }, { kinds: [39_000], limit: 200 }])
      metas = events.select { |e| valid_event?(e, [39_000]) }.index_by { |e| tag_value(e, 'd') }
      now = Time.current
      rows = events.select { |e| valid_event?(e, [39_002]) }.filter_map { |list| channel_row(list, metas, agent, now) }
      rows = rows.uniq { |r| r[:channel_id] }.first(MAX_CHANNELS)
      BuzzChannel.where.not(channel_id: rows.pluck(:channel_id)).delete_all
      BuzzChannel.upsert_all(rows, unique_by: :idx_buzz_channels_channel) if rows.any?
    end

    def channel_row(list, metas, agent, now)
      id = tag_value(list, 'd').to_s
      people = list['tags'].select { |t| t[0] == 'p' && t[1].to_s.match?(HEX64) }
      meta = metas[id]
      return unless id.match?(UUID) && meta && people.any? { |t| t[1] == agent }

      { tenant_id: Current.tenant_id, channel_id: id, name: clean_name(tag_value(meta, 'name')) || 'channel',
        about: clean_name(tag_value(meta, 'about'), 200), channel_type: tag_value(meta, 't').to_s.first(20).presence || 'stream',
        archived: tag_value(meta, 'archived') == 'true',
        members: people.first(500).map { |t| [t[1], t[3].to_s.first(20)] }.to_json, fetched_at: now, created_at: now, updated_at: now }
    end

    def tag_value(event, name)
      event['tags'].find { |t| t[0] == name }&.at(1)
    end

    def present_channel(row, mark, viewer)
      { id: row.channel_id, name: row.name, about: row.about, unread: unread_count(row.channel_id, mark, viewer), default: row.channel_id == channel,
        last_at: iso(messages_scope(row.channel_id).maximum(:posted_at)) }
    end

    def fallback_channel(viewer)
      mark = read_marks(viewer, [channel])[channel]
      { id: channel, name: 'channel', about: nil, unread: unread_count(channel, mark, viewer), default: true,
        last_at: iso(messages_scope(channel).maximum(:posted_at)) }
    end

    def iso(seconds) = seconds && Time.zone.at(seconds).iso8601

    def unread_count(channel_id, read_at, viewer)
      messages_scope(channel_id).where('posted_at > ?', read_at.to_i)
                                .where('rupert_user_id IS NULL OR rupert_user_id <> ?', viewer.id).count
    end

    # read_at per channel for this person; channels without a mark get one now,
    # set to the newest message so far.
    def read_marks(viewer, ids)
      marks = BuzzChatRead.where(user_id: viewer.id, channel: ids).pluck(:channel, :read_at).to_h
      missing = ids - marks.keys
      return marks if missing.empty?

      now = Time.current
      fresh = missing.index_with { |id| messages_scope(id).maximum(:posted_at) || Time.now.to_i }
      rows = fresh.map { |id, at| { tenant_id: Current.tenant_id, user_id: viewer.id, channel: id, read_at: at, created_at: now, updated_at: now } }
      BuzzChatRead.insert_all(rows, unique_by: :idx_buzz_chat_reads_user_channel)
      marks.merge(fresh)
    end

    # --- people ---

    # Looks up the kind 0 profiles of authors, reactors and channel members we
    # have no fresh name for. One relay call for the batch; a person with no
    # profile is remembered as nameless so it is not asked again until the refresh
    # window passes.
    def refresh_profiles
      known = BuzzProfile.fresh.pluck(:pubkey)
      seen = BuzzChannel.limit(MAX_CHANNELS).flat_map(&:member_pubkeys) + BuzzMessage.distinct.limit(500).pluck(:pubkey) +
             BuzzReaction.distinct.limit(200).pluck(:pubkey)
      wanted = (seen.uniq - known).first(PROFILE_BATCH)
      return if wanted.empty?

      events = BuzzRelayClient.query([{ kinds: [0], authors: wanted, limit: wanted.size * 3 }])
      newest = events.select { |e| e.is_a?(Hash) && wanted.include?(e['pubkey']) && e['kind'] == 0 }
                     .group_by { |e| e['pubkey'] }.transform_values { |list| list.max_by { |e| e['created_at'].to_i } }
      now = Time.current
      rows = wanted.map do |pubkey|
        name, display = profile_names(newest[pubkey])
        { tenant_id: Current.tenant_id, pubkey: pubkey, name: name, display_name: display, fetched_at: now, created_at: now, updated_at: now }
      end
      BuzzProfile.upsert_all(rows, unique_by: :idx_buzz_profiles_pubkey, update_only: %i[name display_name fetched_at updated_at])
    rescue BuzzRelayClient::Error
      nil
    end

    def profile_names(event)
      return [nil, nil] unless event && event['content'].to_s.length <= 8000

      data = JSON.parse(event['content'])
      return [nil, nil] unless data.is_a?(Hash)

      [clean_name(data['name']), clean_name(data['display_name'] || data['displayName'])]
    rescue JSON::ParserError
      [nil, nil]
    end

    def clean_name(value, max = 60)
      return nil unless value.is_a?(String)

      value.scrub('').gsub(CONTROL, '').gsub(/\s+/, ' ').strip.first(max).presence
    end

    # --- presenting ---

    # Reply count and newest reply time for the top-level messages in rows.
    def thread_extras(rows)
      ids = rows.reject(&:thread_root).map(&:event_id)
      return {} if ids.empty?

      BuzzMessage.where(thread_root: ids).group(:thread_root).pluck(:thread_root, Arel.sql('COUNT(*)'), Arel.sql('MAX(posted_at)'))
                 .to_h { |root, count, last| [root, { count: count, last: last }] }
    end

    def present_one(row, profile, agent, viewer, extras, reactions)
      is_agent = agent.present? && row.pubkey == agent
      text = row.content
      name = profile&.label
      via_person = nil
      if is_agent && row.client == CLIENT_TAG && (m = text.match(/\A(.{1,60}?)#{Regexp.escape(VIA)}(.*)\z/m))
        via_person = clean_name(m[1])
        text = m[2]
      end
      {
        id: row.event_id, cursor: row.cursor, at: Time.zone.at(row.posted_at).iso8601, text: text, reply: row.reply_to.present?,
        channel: row.channel, root: row.thread_root, edited: row.edited,
        reply_count: extras ? extras[:count] : 0, last_reply_at: extras && iso(extras[:last]), reactions: reactions,
        author: via_person || name || (is_agent ? BuzzAgentPrompt::NAME : short_npub(row.pubkey)),
        key: short_npub(row.pubkey), agent: is_agent, via_rupert: via_person.present?, named: (via_person || name).present?,
        mine: viewer.present? && row.rupert_user_id == viewer.id
      }
    end

    # --- posting helpers ---

    def clean_post(text)
      clean = text.to_s.scrub('').gsub(CONTROL, '').strip
      raise Invalid, 'Type a message first.' if clean.blank?
      raise Invalid, "Please keep it under #{POST_MAX} characters." if clean.length > POST_MAX
      raise Invalid, 'That looks like a private key (nsec). Never post one; delete it and keep it secret.' if clean.match?(NSEC)

      clean
    end

    def sender_name(user)
      user.display_name.to_s.scrub('').gsub(CONTROL, '').gsub(/[:\n]/, ' ').gsub(/\s+/, ' ').strip.first(40).presence || 'Someone'
    end

    # [root, parent] for a reply to message_id, always answering the thread's root
    # (the page shows a thread as a flat list under its root), or nil.
    def thread_reference(channel_id, message_id)
      return if message_id.blank?

      parent = messages_scope(channel_id).find_by(event_id: message_id.to_s) || raise(Invalid, 'That message is not available any more.')
      root = parent.thread_root.presence || parent.event_id
      [root, root]
    end

    # NIP-10 as Buzz resolves it: a direct reply to a top-level message carries a
    # single "reply" marker on the root.
    def thread_tag_list(ref)
      return [] unless ref

      [['e', ref[0], '', 'reply']]
    end

    # A p tag for each person picked in the composer whose @name is still in the
    # text and who belongs to the channel (the agent included).
    def mention_tag_list(channel_id, text, picked)
      people = members(channel_id).index_by { |m| m[:pubkey] }
      Array(picked).map(&:to_s).uniq.first(MENTION_MAX).filter_map do |pubkey|
        person = people[pubkey]
        ['p', pubkey] if person && text.include?("@#{person[:name]}")
      end
    end

    def enforce_rate_limit!(user)
      POST_LIMITS.each do |window, max|
        next if BuzzMessage.where(rupert_user_id: user.id).where(created_at: window.ago..).count < max

        raise RateLimited, 'You are posting quickly. Wait a moment and try again.'
      end
    end

    def store_posted(event, user, thread_ref)
      BuzzMessage.create!(
        event_id: event.id, pubkey: event.pubkey.to_s, kind: event.kind, channel: event.tags.find { |t| t[0] == 'h' }&.at(1),
        content: clean_incoming(event.content), client: CLIENT_TAG, rupert_user_id: user.id, posted_at: event.created_at,
        thread_root: thread_ref&.first, reply_to: thread_ref&.last
      )
    rescue ActiveRecord::RecordNotUnique
      BuzzMessage.find_by(event_id: event.id)
    end
  end
end
