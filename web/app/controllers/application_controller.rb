# frozen_string_literal: true

class ApplicationController < ActionController::Base
  before_action :load_last_sync

  private

  def load_last_sync
    @last_sync = SyncRun.order(startedAt: :desc).first
  end
end
