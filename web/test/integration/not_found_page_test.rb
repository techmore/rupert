# frozen_string_literal: true

require 'test_helper'

class NotFoundPageTest < ActionDispatch::IntegrationTest
  test 'unknown paths return 404 with a link back to the dashboard' do
    get '/definitely-not-a-page'
    assert_response :not_found
    assert_match(/Page not found/, response.body)
    assert_match(%r{href="/}, response.body)
  end
end
