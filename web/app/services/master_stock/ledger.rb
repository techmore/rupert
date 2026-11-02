# frozen_string_literal: true

require 'digest'

module MasterStock
  # Staff stock entry: count, receive, adjust and transfer. Each call appends
  # ledger rows and updates the matching balances in one transaction. A retried
  # submission with the same request token returns the original rows.
  class Ledger
    Result = Struct.new(:entries, :replayed, keyword_init: true) do
      def entry = entries.first
    end

    def initialize(actor:)
      MasterStock.require_actor!(actor)
      @actor = actor
    end

    def record(kind:, item:, site:, quantity:, token:, reason: nil, note: nil, reference: nil, destination_site: nil)
      kind = kind.to_s
      raise Error, 'Choose count, receive, adjust or transfer.' unless StockLedgerEntry::STAFF_KINDS.include?(kind)
      raise Error, 'Reload the form for a valid request token.' unless token.to_s.match?(/\A[\w-]{1,100}\z/)

      reason = reason.to_s.presence
      note = note.to_s.strip.presence
      reference = reference.to_s.strip.presence
      raise Error, 'Notes are limited to 1,000 characters.' if note && note.length > 1000
      raise Error, 'References are limited to 200 characters.' if reference && reference.length > 200

      units = whole_number(quantity)
      payload = { kind: kind, item: item&.id, site: site&.id, quantity: units, reason: reason, note: note,
                  reference: reference, destination: destination_site&.id }
      digest = Digest::SHA256.hexdigest(payload.to_json)

      MasterStock.serialized do
        prior = replay(token, digest)
        return prior if prior

        check_pool!(item, site)
        entries = case kind
        when 'count' then [count!(item, site, units, token, digest, note, reference)]
        when 'receive' then [receive!(item, site, units, token, digest, note, reference)]
        when 'adjust' then [adjust!(item, site, units, reason, token, digest, note, reference)]
        when 'transfer' then transfer!(item, site, destination_site, units, token, digest, note, reference)
        end
        Result.new(entries: entries, replayed: false)
      end
    rescue ActiveRecord::RecordNotUnique
      replay(token, digest) || raise(Error, 'This request was already recorded. Reload the page.')
    rescue ActiveRecord::RecordInvalid => e
      raise Error, e.record.errors.full_messages.to_sentence
    end

    private

    def count!(item, site, units, token, digest, note, reference)
      raise Error, "Enter the counted total as a whole number from 0 to #{MasterStock::MAX_UNITS}." unless units&.between?(0, MasterStock::MAX_UNITS)

      balance = StockBalance.find_by(stock_item: item, stock_site: site)
      before = balance&.on_hand
      balance ||= StockBalance.new(stock_item: item, stock_site: site, tenant_id: Current.tenant_id)
      balance.update!(on_hand: units, counted_at: Time.current)
      entry!(item, site, 'count', units - before.to_i, before, units, token, digest, note: note, reference: reference)
    end

    def receive!(item, site, units, token, digest, note, reference)
      raise Error, 'Enter the units received as a whole number above zero.' unless units&.between?(1, MasterStock::MAX_UNITS)

      move!(item, site, 'receive', units, token, digest, note: note, reference: reference)
    end

    def adjust!(item, site, units, reason, token, digest, note, reference)
      unless units && units != 0 && units.abs <= MasterStock::MAX_UNITS
        raise Error, 'Enter the change as a whole number, for example -2 or 3.'
      end
      raise Error, 'Choose a reason for this adjustment.' unless StockLedgerEntry::REASONS.key?(reason)
      raise Error, 'Add a note explaining “Other”.' if reason == 'other' && note.blank?

      move!(item, site, 'adjust', units, token, digest, reason: reason, note: note, reference: reference)
    end

    def transfer!(item, site, destination, units, token, digest, note, reference)
      raise Error, 'Enter the units moved as a whole number above zero.' unless units&.between?(1, MasterStock::MAX_UNITS)
      raise Error, 'Choose a different destination site.' unless destination && destination.id != site.id

      check_pool!(item, destination)
      unless StockBalance.exists?(stock_item: item, stock_site: destination)
        raise Error, "Count #{item.name} at #{destination.name} before moving stock there."
      end
      group = SecureRandom.uuid
      [move!(item, site, 'transfer_out', -units, token, digest, note: note, reference: reference, group: group),
       move!(item, destination, 'transfer_in', units, token, digest, note: note, reference: reference, group: group)]
    end

    def move!(item, site, kind, delta, token, digest, reason: nil, note: nil, reference: nil, group: nil)
      balance = StockBalance.find_by(stock_item: item, stock_site: site)
      raise Error, "Count #{item.name} at #{site.name} first. Rupert does not assume a starting quantity." unless balance

      after = balance.on_hand + delta
      if after.negative?
        raise Error, "Rupert shows #{balance.on_hand} on hand at #{site.name}. Recount if the shelf has more."
      end
      raise Error, 'That would exceed the maximum quantity.' if after > MasterStock::MAX_UNITS

      before = balance.on_hand
      balance.update!(on_hand: after)
      entry!(item, site, kind, delta, before, after, token, digest, reason: reason, note: note, reference: reference, group: group)
    end

    def entry!(item, site, kind, delta, before, after, token, digest, reason: nil, note: nil, reference: nil, group: nil)
      StockLedgerEntry.create!(tenant_id: Current.tenant_id, stock_item: item, stock_site: site, kind: kind, delta: delta,
        quantity_before: before, quantity_after: after, reason: reason, note: note, reference: reference, origin: 'rupert',
        transfer_group: group, actor: @actor.email, request_token: token, payload_digest: digest, created_at: Time.current)
    end

    def check_pool!(item, site)
      unless item.is_a?(StockItem) && site.is_a?(StockSite) && item.tenant_id == Current.tenant_id && site.tenant_id == Current.tenant_id
        raise Error, 'Choose an item and site from this workspace.'
      end
      raise Error, "#{item.name} is archived." unless item.active
      raise Error, "#{site.name} is inactive." unless site.active
    end

    def replay(token, digest)
      entries = StockLedgerEntry.where(request_token: token).order(:id).to_a
      return if entries.empty?
      unless entries.all? { |entry| entry.payload_digest == digest && entry.actor == @actor.email }
        raise Error, 'This form was already submitted with different details. Reload the page.'
      end

      Result.new(entries: entries, replayed: true)
    end

    def whole_number(value)
      text = value.to_s.strip
      text.match?(/\A[-+]?\d{1,9}\z/) ? text.to_i : nil
    end
  end
end
