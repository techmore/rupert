# frozen_string_literal: true

require "test_helper"

class BuzzResponderTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown { Current.tenant = nil }

  def pending_count
    count = InventoryCount.create!(countedAt: Time.current, tenant_id: Current.tenant_id)
    count.submit!
    count
  end

  test "help returns the command list" do
    reply = BuzzResponder.respond("help")
    assert_includes reply, "Rupert"
    assert_includes reply, "sync now"
  end

  test "sync now enqueues a sync and confirms" do
    assert_enqueued_with(job: SyncJob) do
      reply = BuzzResponder.respond("please run a sync now")
      assert_includes reply, "Sync started"
    end
  end

  test "status reports last sync, pending counts, and alerts" do
    SyncRun.create!(mode: "manual", status: "success", source: "all",
      actor: "tester", startedAt: 1.hour.ago, tenant_id: Current.tenant_id)
    pending_count

    reply = BuzzResponder.respond("status")
    assert_includes reply, "Last sync"
    assert_includes reply, "1 pending manual count"
  end

  test "counts lists pending manual counts" do
    pending_count
    reply = BuzzResponder.respond("counts")
    assert_includes reply, "Pending manual counts"
  end

  test "unknown message gets an acknowledgement pointing to help" do
    reply = BuzzResponder.respond("hello there")
    assert_includes reply, "help"
  end

  test "blank message returns nil" do
    assert_nil BuzzResponder.respond("   ")
  end
end
