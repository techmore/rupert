# frozen_string_literal: true

require 'test_helper'

class Lms::EnrollerTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @manager = User.create!(tenant: @tenant, email: 'lms-m@example.com', name: 'Mo', role: 'manager', password: 'password123')
    @staff = User.create!(tenant: @tenant, email: 'lms-s@example.com', name: 'Sam', role: 'employee', password: 'password123')
    @course = Lms::Course.create!(slug: 'rules', title: 'Rules', status: 'published')
    @course.lessons.create!(slug: 'l', title: 'L', body: 'x')
  end

  teardown { Current.reset }

  test 'a role rule enrols matching people as required with a due date, once' do
    rule = @course.assignment_rules.create!(role: 'manager', required: true, due_days: 30)
    created = Lms::Enroller.apply_rule!(rule)
    assert_equal [@manager], created.map(&:user)
    enrollment = created.first
    assert enrollment.required?
    assert_equal Date.current + 30, enrollment.due_on
    assert_equal 'rule', enrollment.source
    assert_equal rule, enrollment.assignment_rule
    assert_empty Lms::Enroller.apply_rule!(rule)
    assert_empty Lms::Enroller.ensure_for(@manager)
    assert_empty Lms::Enroller.ensure_for(@staff)
    assert_equal 1, Lms::Enrollment.count
  end

  test 'an everyone rule reaches every active account and a draft course reaches nobody' do
    @course.assignment_rules.create!(role: nil)
    assert_equal 1, Lms::Enroller.ensure_for(@staff).size
    draft = Lms::Course.create!(slug: 'draft', title: 'Draft', status: 'draft')
    draft.assignment_rules.create!(role: nil)
    assert_empty Lms::Enroller.ensure_for(@manager).select { |enrollment| enrollment.course == draft }
    @staff.update!(active: false)
    assert_empty Lms::Enroller.ensure_for(@staff)
  end

  test 'manual assignment only tightens an existing enrollment' do
    Lms::Enroller.self_enroll!(@course, @staff)
    created, existing = Lms::Enroller.assign!(@course, [@staff, @manager], actor: @manager, required: true, due_on: Date.current + 7)
    assert_equal [@manager], created.map(&:user)
    assert_equal [@staff], existing.map(&:user)
    staff_enrollment = existing.first
    assert staff_enrollment.required?
    assert_equal Date.current + 7, staff_enrollment.due_on
    assert_equal 'self', staff_enrollment.source
    _, again = Lms::Enroller.assign!(@course, [@staff], actor: @manager, required: false, due_on: Date.current + 60)
    assert again.first.required?, 'required never loosens'
    assert_equal Date.current + 7, again.first.due_on, 'due date never moves later'
  end

  test 'people and courses from another workspace never mix' do
    other = Tenant.create!(id: 'other-tenant', name: 'Other', subdomain: 'other', status: 'active')
    outsider = User.create!(tenant: other, email: 'out@example.com', role: 'manager', password: 'password123')
    assert_raises(ArgumentError) { Lms::Enroller.self_enroll!(@course, outsider) }
    @course.assignment_rules.create!(role: 'manager')
    assert_empty Lms::Enroller.ensure_for(outsider)
  end
end
