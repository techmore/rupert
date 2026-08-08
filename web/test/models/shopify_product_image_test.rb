# frozen_string_literal: true

require "test_helper"

class ShopifyProductImageTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown { Current.tenant = nil }

  test "thumbnail_url appends width and height params" do
    product = ShopifyProduct.create!(
      id: "gid://shopify/Product/1",
      title: "CBD Oil",
      status: "ACTIVE",
      featuredImageUrl: "https://cdn.shopify.com/s/files/1/2/x.png?v=1",
    )
    assert_equal "https://cdn.shopify.com/s/files/1/2/x.png?v=1&width=96&height=96",
      product.thumbnail_url
  end

  test "thumbnail_url handles urls without query string" do
    product = ShopifyProduct.create!(
      id: "gid://shopify/Product/2",
      title: "CBD Gummies",
      status: "ACTIVE",
      featuredImageUrl: "https://cdn.shopify.com/s/files/1/2/g.png",
    )
    assert_equal "https://cdn.shopify.com/s/files/1/2/g.png?width=96&height=96",
      product.thumbnail_url
  end

  test "thumbnail_url returns nil without an image" do
    product = ShopifyProduct.create!(
      id: "gid://shopify/Product/3",
      title: "No Image",
      status: "ACTIVE",
    )
    assert_nil product.thumbnail_url
  end
end
