# frozen_string_literal: true

class RelaxAccessLogsTenantId < ActiveRecord::Migration[8.1]
  def change
    change_column_null :access_logs, :tenant_id, true
  end
end
