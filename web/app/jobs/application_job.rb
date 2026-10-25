# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  # RequestStore is only reset by its Rack middleware, but a worker thread runs many
  # jobs: without this a job would reuse the previous job's cached settings
  # (EnvStore credentials, connection keys), possibly another workspace's.
  around_perform do |_job, block|
    RequestStore.clear!
    block.call
  ensure
    RequestStore.clear!
  end
  after_enqueue { |job| SyncObservability.queued(job) }
  around_perform { |job, block| SyncObservability.perform(job, &block) }

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
end
