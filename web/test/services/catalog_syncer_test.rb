# frozen_string_literal: true

require "test_helper"

class CatalogSyncerTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    EnvStore::MANAGED_KEYS.freeze unless EnvStore::MANAGED_KEYS.frozen?
  end

  teardown do
    Setting.where(key: "SYNC_HISTORY_DAYS").delete_all
    Current.tenant = nil
  end

  test "history_lookback defaults to 30 days when unset" do
    assert_equal 30.days, CatalogSyncer.send(:history_lookback)
  end

  test "history_lookback honors SYNC_HISTORY_DAYS" do
    EnvStore.set("SYNC_HISTORY_DAYS", "3650")
    assert_equal 3650.days, CatalogSyncer.send(:history_lookback)
  end

  test "paginate_orders walks all pages" do
    page1 = { "orders" => { "nodes" => [{ "id" => "a" }, { "id" => "b" }],
                            "pageInfo" => { "hasNextPage" => true, "endCursor" => "c1" } } }
    page2 = { "orders" => { "nodes" => [{ "id" => "c" }],
                            "pageInfo" => { "hasNextPage" => false, "endCursor" => "c2" } } }

    ShopifyClient.stubs(:graphql)
                 .returns(page1)
                 .then.returns(page2)

    result = CatalogSyncer.send(:paginate_orders, "2026-01-01")

    assert_equal %w[a b c], result["nodes"].map { |n| n["id"] }
    refute result["pageInfo"]["hasNextPage"]
  end
end
