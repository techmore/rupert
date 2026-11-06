# frozen_string_literal: true

require 'test_helper'

class Lms::SeederTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  test 'loads the shipped course once and is a no-op afterwards' do
    courses = Lms::Seeder.sync!
    assert_equal 1, courses.size
    course = courses.first
    assert_equal 'how-our-card-payments-work', course.slug
    assert course.published?
    assert_equal 8, course.lessons.count
    assert course.lessons.all? { |lesson| lesson.questions.count.between?(2, 4) }
    assert course.glossary_terms.count > 20
    assert_equal 3, course.assignment_rules.count
    assert course.assignment_rules.find_by(role: 'manager').required?
    assert_empty Lms::Seeder.sync!
    assert_nothing_raised { Lms::Seeder.ensure! }
    assert_equal 1, Lms::Course.count
  end

  test 'a newer version updates lessons in place so progress survives, but an edited course is left alone' do
    course = Lms::Seeder.sync!.first
    lesson = course.lessons.first
    user = users(:regular_user)
    enrollment = Lms::Enroller.self_enroll!(course, user)
    Lms::Progress.new(enrollment).viewed!(lesson)
    data = YAML.safe_load_file(Lms::Seeder.files.first)
    data['version'] += 1
    data['lessons'][0]['title'] = 'Renamed lesson'
    data['lessons'].pop
    Lms::Seeder.new(@tenant.id, data).sync!
    course.reload
    assert_equal data['version'], course.seed_version
    assert_equal 'Renamed lesson', lesson.reload.title
    assert_equal 7, course.lessons.count
    assert enrollment.reload.progress_for(lesson).viewed?

    course.touch_edited!(user)
    data['version'] += 1
    data['lessons'][0]['title'] = 'Changed again'
    assert_nil Lms::Seeder.new(@tenant.id, data).sync!
    assert_equal 'Renamed lesson', lesson.reload.title
  end

  test 'seeds are per workspace' do
    other = Tenant.create!(id: 'other-tenant', name: 'Other', subdomain: 'other', status: 'active')
    Lms::Seeder.sync!(other.id)
    assert_equal 0, Lms::Course.count, 'the current workspace sees nothing'
    assert_equal 1, Lms::Course.tenant_unscoped(other.id).count
  end
end
