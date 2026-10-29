# frozen_string_literal: true

module Mcp
  # Safety rails shared by the MCP task-write tools (create_task, update_task):
  # a per-token write cap and 24-hour idempotency keys. State lives in the
  # tenant's ActivityLog, which is durable and already audited, so no extra
  # table is needed. Dry runs never count against the cap and never record keys.
  module TaskWriteGuard
    # Task writes one token may make per rolling minute (dry runs excluded).
    MAX_TASK_WRITES_PER_MINUTE = 20
    IDEMPOTENCY_WINDOW = 24.hours
    WRITE_ACTION = 'mcp_task_write'
    IDEMPOTENCY_ACTION = 'mcp_idempotency_key'

    private

    def dry_run?(args)
      args['dry_run'] == true
    end

    def enforce_write_cap!
      recent = ActivityLog.where(action: WRITE_ACTION, subject_label: token_label).where(created_at: 1.minute.ago..).count
      return if recent < MAX_TASK_WRITES_PER_MINUTE

      raise ToolError.new("This token has made #{recent} task writes in the last minute (limit #{MAX_TASK_WRITES_PER_MINUTE}). " \
                          'Wait a minute and retry, batch the work into fewer tasks, or preview with dry_run: true. ' \
                          'If this is unexpected, ask the workspace owner to review or revoke the token.', kind: 'tool_error')
    end

    def record_write!
      ActivityLog.create!(tenant_id: tenant.id, user_id: user.id, actor_name: user.display_name, action: WRITE_ACTION, subject_label: token_label)
    end

    def token_label = "token:#{token.id}"

    def idempotency_digest(key)
      Digest::SHA256.hexdigest("#{token.id}:#{key}")
    end

    # The stored result of an earlier call with this key from this token, or nil.
    def idempotent_replay(key)
      return if key.blank?

      row = ActivityLog.where(action: IDEMPOTENCY_ACTION, subject_label: idempotency_digest(key)).where(created_at: IDEMPOTENCY_WINDOW.ago..).order(:id).first
      return unless row

      stored = JSON.parse(row.details)
      result(stored['text'], stored['data'].deep_symbolize_keys.merge(idempotent_replay: true))
    rescue JSON::ParserError
      nil
    end

    def remember_idempotent(key, outcome)
      return if key.blank?

      ActivityLog.create!(tenant_id: tenant.id, user_id: user.id, actor_name: user.display_name, action: IDEMPOTENCY_ACTION,
        subject_label: idempotency_digest(key), details: JSON.generate({ text: outcome.text, data: outcome.data }))
    end
  end
end
