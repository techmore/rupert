# frozen_string_literal: true

require "test_helper"

class DataCacheTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
  end

  teardown do
    Current.tenant = nil
    Rails.cache = ActiveSupport::Cache::NullStore.new
  end

  test "caches the block result across calls" do
    calls = 0
    3.times do
      DataCache.fetch("test/cached") do
        calls += 1
        "value-#{calls}"
      end
    end
    assert_equal 1, calls
  end

  test "bump! invalidates cached values" do
    first = DataCache.fetch("test/versioned") { "v0" }
    assert_equal "v0", first

    DataCache.bump!
    second = DataCache.fetch("test/versioned") { "v1" }
    assert_equal "v1", second
  end

  test "version increments on bump" do
    before = DataCache.version
    DataCache.bump!
    assert_equal before + 1, DataCache.version
  end

  test "keys are tenant-scoped" do
    other = Tenant.create!(name: "Other", subdomain: "other")
    Current.tenant = other
    DataCache.bump!

    Current.tenant = tenants(:default_tenant)
    # The default tenant's cache entry should be untouched by another tenant's bump
    assert_equal 0, DataCache.version
  end

  test "dashboard presenter reconcile summary is cached" do
    DataCache.fetch("dashboard/reconcile_summary") { { drift_count: 5, actionable: 2, blocked_adjustments: 0, total: 10 } }
    calls = 0
    DataCache.fetch("dashboard/reconcile_summary") do
      calls += 1
      :recomputed
    end
    assert_equal 0, calls
  end
end
