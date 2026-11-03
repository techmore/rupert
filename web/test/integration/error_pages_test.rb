# frozen_string_literal: true

require 'test_helper'

# The static error pages (public/404, 422, 500) use the app's appearances: Herbal unless
# this browser saved another one in the account menu, never the phone's dark mode.
class ErrorPagesTest < ActionDispatch::IntegrationTest
  THEMES = %w[light mist sepia dark].freeze

  %w[404 422 500].each do |code|
    test "the #{code} page follows the saved appearance" do
      html = Rails.public_path.join("#{code}.html").read
      assert_includes html, 'localStorage.getItem("rupert-theme")'
      THEMES.each { |theme| assert_includes html, %(:root[data-theme="#{theme}"]) }
      assert_not_includes html, 'prefers-color-scheme'
    end
  end

  test 'an unknown page serves the 404 page' do
    get '/no-such-page-anywhere'
    assert_response :not_found
    assert_includes response.body, 'rupert-theme'
  end
end
