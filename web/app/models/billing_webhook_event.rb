# frozen_string_literal: true

# One row per Stripe event id, so a redelivered event is acknowledged without being applied again.
# Global (not workspace-scoped): Stripe events arrive before any workspace is known.
class BillingWebhookEvent < ApplicationRecord
  validates :stripe_event_id, presence: true # unique by index
  validates :event_type, presence: true

  # Applies the block once per event id. A delivery whose block raises is left unprocessed,
  # so Stripe's retry runs it again; a delivery of an already processed event does nothing.
  def self.process(event)
    id = event['id'].to_s
    raise RupertBilling::Error, 'Webhook event has no id.' unless id.match?(/\Aevt_[A-Za-z0-9_]{1,200}\z/)

    row = find_by(stripe_event_id: id)
    if row
      where(id: row.id).update_all(['deliveries = deliveries + 1, updated_at = ?', Time.current])
      return :duplicate if row.processed_at
    else
      row = record_first_delivery(id, event)
    end
    yield
    row.update!(processed_at: Time.current)
    :processed
  end

  # Two deliveries of one event can race: the unique index decides, and the loser reads the winner's row.
  def self.record_first_delivery(id, event)
    create!(stripe_event_id: id, event_type: event['type'].to_s.first(120).presence || 'unknown',
      event_created_at: event['created'].is_a?(Integer) ? Time.zone.at(event['created']) : nil)
  rescue ActiveRecord::RecordNotUnique
    find_by!(stripe_event_id: id)
  end
end
