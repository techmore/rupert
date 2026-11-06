# frozen_string_literal: true

require 'test_helper'

# Staff app: pay summary with tips, and declaring cash tips, own records only.
class EmployeeTipsApiTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, name: 'Api Worker', email: 'api-tips@example.com', role: 'employee', password: 'password123')
    @worker = People::Employee.create!(user: @user, first_name: 'Api', last_name: 'Worker', employment_type: 'part_time')
    @at = Time.zone.parse('2026-11-05 09:00')
    @shift = ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name, employment_type: 'part_time',
      started_at: @at, ended_at: @at + 6.hours, request_token: SecureRandom.uuid)
    TipAllocation.create!(employee: @worker, clock_shift: @shift, source_kind: 'dejavoo_feed_event', source_id: 1, tip_method: 'pool', status: 'estimated',
      amount_cents: 450, gross_tip_cents: 900, share_count: 2, occurred_at: @at + 2.hours, business_date: @at.to_date)
    Current.reset
  end

  def headers
    post '/api/v1/employee/session', params: { email: @user.email, password: 'password123', device_name: 'Test phone' }, as: :json
    assert_response :created
    { 'Authorization' => "Bearer #{response.parsed_body.fetch('token')}" }
  end

  test 'pay summary and cash tip declaration' do
    travel_to Time.zone.parse('2026-11-06 12:00') do
      auth = headers
      get '/api/v1/employee/pay', params: { period: '2026-11-05' }, headers: auth
      assert_response :success
      data = response.parsed_body.fetch('data')
      assert_equal [6.0, 450, 450, 0, false], [data['paid_hours'], data['tip_cents'], data['estimated_tip_cents'], data['cash_tip_cents'], data['final']]
      assert_equal 1, data['tips'].size
      post '/api/v1/employee/tips', params: { cash_tips: { amount_cents: 1200, shift_id: @shift.id } }, headers: auth, as: :json
      assert_response :created
      get '/api/v1/employee/pay', params: { period: '2026-11-05' }, headers: auth
      assert_equal 1200, response.parsed_body.dig('data', 'cash_tip_cents')
      post '/api/v1/employee/tips', params: { cash_tips: { amount_cents: -5, shift_id: @shift.id } }, headers: auth, as: :json
      assert_response :unprocessable_entity
      get '/api/v1/employee/pay', headers: {}
      assert_response :unauthorized
    end
  end
end
