# frozen_string_literal: true

require "test_helper"

class PageGuidesTest < ActiveSupport::TestCase
  test "for_path resolves the right guide by URL prefix" do
    assert_equal "dashboard", PageGuides.for_path("/").key
    assert_equal "sales", PageGuides.for_path("/sales").key
    assert_equal "sales", PageGuides.for_path("/sales?source=square").key
    assert_equal "sizes", PageGuides.for_path("/size_families").key
    assert_equal "access_log", PageGuides.for_path("/access_logs").key
    assert_equal "finance", PageGuides.for_path("/finance/accounts").key
    assert_equal "users", PageGuides.for_path("/users").key
    assert_equal "inventory", PageGuides.for_path("/inventory").key
  end

  test "every guide has sections and tips" do
    PageGuides.keys.each do |key|
      guide = PageGuides.for(key)
      assert guide.summary.present?, "#{key} missing summary"
      assert guide.sections.any?, "#{key} missing sections"
    end
  end
end
