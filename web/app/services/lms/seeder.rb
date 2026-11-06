# frozen_string_literal: true

# Loads the courses shipped with Rupert (db/seeds/lms/*.yml) into a workspace. Runs when the
# Learning center is opened and from `bin/rails lms:seed`, so production gets a new course on
# deploy without a console step.
#
# Rules: a course is matched by `seed_key`. A newer file `version` updates the title, lessons
# (matched by slug, so progress survives), questions and glossary; it never touches a course an
# owner has edited (`edited_at`), and default assignment rules are written only on first load.
class Lms::Seeder
  DIR = Rails.root.join('db/seeds/lms')

  def self.files = Dir[DIR.join('*.yml')].sort

  # Every shipped course, for one workspace. Returns the courses created or updated.
  def self.sync!(tenant_id = Current.tenant_id)
    return [] if tenant_id.blank?

    files.filter_map { |file| new(tenant_id, YAML.safe_load_file(file, permitted_classes: [], aliases: false)).sync! }
  end

  # Cheap check used on page views: only reads when a file is newer than the workspace copy.
  def self.ensure!(tenant_id = Current.tenant_id)
    return if tenant_id.blank?

    have = Lms::Course.tenant_unscoped(tenant_id).where.not(seed_key: nil).pluck(:seed_key, :seed_version).to_h
    files.each do |file|
      data = YAML.safe_load_file(file, permitted_classes: [], aliases: false)
      next if have[data['key']].to_i >= data['version'].to_i

      new(tenant_id, data).sync!
    end
  end

  def initialize(tenant_id, data)
    @tenant_id = tenant_id
    @data = data
  end

  def sync!
    course = Lms::Course.tenant_unscoped(@tenant_id).find_or_initialize_by(seed_key: @data.fetch('key'))
    fresh = course.new_record?
    return nil if !fresh && course.seed_version.to_i >= @data['version'].to_i
    return nil if !fresh && course.edited_at.present?

    Lms::Course.transaction do
      course.assign_attributes(tenant_id: @tenant_id, slug: course.slug.presence || @data.fetch('slug', @data['key']),
        title: @data.fetch('title'), summary: @data['summary'], description: @data['description'], badge_title: @data['badge_title'],
        locale: @data.fetch('locale', 'en'), position: @data.fetch('position', 0), seed_version: @data['version'].to_i,
        status: fresh ? @data.fetch('status', 'published') : course.status)
      course.save!
      sync_glossary(course)
      sync_lessons(course)
      sync_rules(course) if fresh
    end
    course
  end

  private

  def sync_glossary(course)
    keys = []
    Array(@data['glossary']).each do |entry|
      term = course.glossary_terms.find_or_initialize_by(key: entry.fetch('key'))
      term.assign_attributes(tenant_id: @tenant_id, term: entry.fetch('term'), definition: entry.fetch('definition'))
      term.save!
      keys << term.key
    end
    course.glossary_terms.where.not(key: keys).destroy_all
  end

  def sync_lessons(course)
    slugs = []
    Array(@data['lessons']).each_with_index do |entry, index|
      lesson = course.lessons.find_or_initialize_by(slug: entry.fetch('slug'))
      lesson.assign_attributes(tenant_id: @tenant_id, title: entry.fetch('title'), summary: entry['summary'],
        minutes: entry.fetch('minutes', 3), position: index + 1, body: entry.fetch('body'), diagram: entry['diagram'])
      lesson.save!
      sync_questions(lesson, Array(entry['quiz']))
      slugs << lesson.slug
    end
    course.lessons.where.not(slug: slugs).destroy_all
    course.lessons.reset
  end

  def sync_questions(lesson, entries)
    existing = lesson.questions.to_a
    entries.each_with_index do |entry, index|
      question = existing[index] || lesson.questions.build(tenant_id: @tenant_id)
      question.assign_attributes(position: index + 1, prompt: entry.fetch('prompt'), choices: entry.fetch('choices'),
        answer_index: entry.fetch('answer'), explanation: entry['explanation'])
      question.save!
    end
    existing.drop(entries.size).each(&:destroy!)
    lesson.questions.reset
  end

  def sync_rules(course)
    Array(@data['assign']).each do |entry|
      course.assignment_rules.create!(tenant_id: @tenant_id, role: entry['role'], required: entry.fetch('required', false), due_days: entry['due_days'])
    end
  end
end
