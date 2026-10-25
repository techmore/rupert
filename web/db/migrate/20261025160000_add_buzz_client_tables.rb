# frozen_string_literal: true

# Tables for the optional Buzz module (web/engines/buzz). They exist whether or
# not the module is on; nothing reads or writes them while it is off. The kept
# buzz_messages rows are left as they are (older rows simply have no thread).
class AddBuzzClientTables < ActiveRecord::Migration[8.1]
  def change
    add_column :buzz_messages, :thread_root, :string, limit: 64
    safety_assured { add_column :buzz_messages, :edited, :boolean, null: false, default: false }
    add_index :buzz_messages, %i[tenant_id thread_root], name: 'idx_buzz_messages_thread'

    # The channels the Rupert identity belongs to (relay kinds 39000 / 39002).
    create_table :buzz_channels do |t|
      t.string :tenant_id, null: false
      t.string :channel_id, null: false
      t.string :name, null: false
      t.string :about
      t.string :channel_type, limit: 20
      t.boolean :archived, null: false, default: false
      t.text :members, null: false, default: '[]' # JSON: [[pubkey, role], ...]
      t.datetime :fetched_at, null: false
      t.timestamps
      t.index %i[tenant_id channel_id], unique: true, name: 'idx_buzz_channels_channel'
    end

    # Reactions (kind 7) to copied messages.
    create_table :buzz_reactions do |t|
      t.string :tenant_id, null: false
      t.string :event_id, null: false, limit: 64
      t.string :target_id, null: false, limit: 64
      t.string :channel, null: false
      t.string :pubkey, null: false, limit: 64
      t.string :emoji, null: false, limit: 64
      t.bigint :rupert_user_id
      t.bigint :posted_at, null: false
      t.timestamps
      t.index %i[tenant_id event_id], unique: true, name: 'idx_buzz_reactions_event'
      t.index %i[tenant_id target_id], name: 'idx_buzz_reactions_target'
    end

    # How far each person has read each channel (unread markers).
    create_table :buzz_chat_reads do |t|
      t.string :tenant_id, null: false
      t.bigint :user_id, null: false
      t.string :channel, null: false
      t.bigint :read_at, null: false
      t.timestamps
      t.index %i[tenant_id user_id channel], unique: true, name: 'idx_buzz_chat_reads_user_channel'
    end
  end
end
