# frozen_string_literal: true

class CreateActivityLogs < ActiveRecord::Migration[8.1]
  def change
    create_table(:activity_logs) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:user_id)
      t.string(:actor_name)
      t.string(:action, null: false)
      t.string(:subject_type)
      t.string(:subject_id)
      t.string(:subject_label)
      t.text(:details)
      t.timestamps

      t.index(%i[tenant_id created_at])
      t.index(%i[tenant_id subject_type subject_id])
    end
  end
end
