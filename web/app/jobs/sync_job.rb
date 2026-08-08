# frozen_string_literal: true

class SyncJob < ApplicationJob
  queue_as :default

  def perform(payload = {})
    mode = payload["mode"] || payload[:mode] || "manual"
    source = payload["source"] || payload[:source]
    actor = payload["actor"] || payload[:actor] || "scheduler"

    if source.present?
      SyncEngine.run_source!(source, actor: actor)
    else
      SyncEngine.run!(mode: mode, actor: actor)
    end
  end
end
