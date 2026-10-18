# frozen_string_literal: true

class CreateMarketingEmail < ActiveRecord::Migration[8.1]
  def change
    add_column :customers, :marketing_consent_at, :datetime
    add_column :customers, :marketing_consent_source, :string
    add_column :customers, :marketing_unsubscribed_at, :datetime

    create_table :marketing_email_domains do |t|
      t.string :tenant_id, null: false
      t.string :domain, null: false
      t.string :kind, null: false, default: 'custom'
      t.string :status, null: false, default: 'pending'
      t.string :provider_id
      t.text :dns_records_json
      t.text :last_error
      t.datetime :verified_at
      t.datetime :checked_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index :tenant_id
      t.index [:tenant_id, :domain], unique: true
    end
    add_foreign_key :marketing_email_domains, :tenants
    add_check_constraint :marketing_email_domains, "status IN ('pending', 'verified', 'failed')", name: 'marketing_email_domain_status'
    add_check_constraint :marketing_email_domains, "kind IN ('custom', 'shared')", name: 'marketing_email_domain_kind'

    create_table :marketing_email_senders do |t|
      t.string :tenant_id, null: false
      t.references :email_domain, null: false, foreign_key: { to_table: :marketing_email_domains }
      t.string :from_name, null: false
      t.string :local_part, null: false
      t.string :reply_to
      t.boolean :is_default, null: false, default: false
      t.timestamps
      t.index :tenant_id
      t.index [:tenant_id, :email_domain_id, :local_part], unique: true, name: 'marketing_email_sender_address'
    end
    add_foreign_key :marketing_email_senders, :tenants

    create_table :marketing_email_campaigns do |t|
      t.string :tenant_id, null: false
      t.references :sender, null: false, foreign_key: { to_table: :marketing_email_senders }
      t.string :name, null: false
      t.string :subject, null: false
      t.text :body, null: false
      t.string :segment_status
      t.string :segment_source
      t.string :segment_tag
      t.string :status, null: false, default: 'draft'
      t.datetime :scheduled_at
      t.datetime :sent_at
      t.bigint :approved_by_id
      t.text :last_error
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index :tenant_id
      t.index [:tenant_id, :status]
    end
    add_foreign_key :marketing_email_campaigns, :tenants
    add_foreign_key :marketing_email_campaigns, :users, column: :approved_by_id
    add_check_constraint :marketing_email_campaigns,
      "status IN ('draft', 'approved', 'sending', 'sent', 'paused', 'failed')", name: 'marketing_email_campaign_status'

    create_table :marketing_email_recipients do |t|
      t.string :tenant_id, null: false
      t.references :campaign, null: false, foreign_key: { to_table: :marketing_email_campaigns }
      t.bigint :customer_id, null: false
      t.string :email, null: false
      t.string :status, null: false, default: 'queued'
      t.string :provider_message_id
      t.text :last_error
      t.datetime :sent_at
      t.timestamps
      t.index :tenant_id
      t.index [:campaign_id, :customer_id], unique: true
      t.index :provider_message_id
    end
    add_foreign_key :marketing_email_recipients, :tenants
    add_foreign_key :marketing_email_recipients, :customers
    add_check_constraint :marketing_email_recipients,
      "status IN ('queued', 'sent', 'bounced', 'complained', 'failed', 'skipped')", name: 'marketing_email_recipient_status'

    create_table :marketing_email_suppressions do |t|
      t.string :tenant_id, null: false
      t.string :email, null: false
      t.string :reason, null: false
      t.timestamps
      t.index :tenant_id
      t.index [:tenant_id, :email], unique: true
    end
    add_foreign_key :marketing_email_suppressions, :tenants
  end
end
