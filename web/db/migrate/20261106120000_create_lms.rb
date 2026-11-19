# frozen_string_literal: true

# The Learning center (LMS): courses, their lessons and quiz questions as editable data, a
# glossary per course, who is assigned what (by role or by hand), and each person's progress.
# Additive only. Progress rows are per enrollment so a re-assigned course starts clean.
class CreateLms < ActiveRecord::Migration[8.1]
  def change
    create_table :lms_courses do |t|
      t.string :tenant_id, null: false
      t.string :slug, null: false
      t.string :title, null: false
      t.string :summary
      t.text :description
      t.string :status, null: false, default: 'draft'
      t.string :locale, null: false, default: 'en'
      t.string :badge_title
      t.integer :position, null: false, default: 0
      t.string :seed_key
      t.integer :seed_version
      t.datetime :edited_at
      t.bigint :created_by_id
      t.bigint :updated_by_id
      t.timestamps
    end
    add_index :lms_courses, %i[tenant_id slug], unique: true
    add_index :lms_courses, %i[tenant_id seed_key]

    create_table :lms_lessons do |t|
      t.string :tenant_id, null: false
      t.bigint :course_id, null: false
      t.string :slug, null: false
      t.string :title, null: false
      t.string :summary
      t.integer :minutes, null: false, default: 3
      t.integer :position, null: false, default: 0
      t.text :body
      t.string :diagram
      t.timestamps
    end
    add_index :lms_lessons, %i[course_id slug], unique: true
    add_index :lms_lessons, %i[tenant_id course_id position]

    create_table :lms_questions do |t|
      t.string :tenant_id, null: false
      t.bigint :lesson_id, null: false
      t.integer :position, null: false, default: 0
      t.text :prompt, null: false
      t.text :choices_json, null: false
      t.integer :answer_index, null: false, default: 0
      t.text :explanation
      t.timestamps
    end
    add_index :lms_questions, %i[lesson_id position]

    create_table :lms_glossary_terms do |t|
      t.string :tenant_id, null: false
      t.bigint :course_id, null: false
      t.string :key, null: false
      t.string :term, null: false
      t.text :definition, null: false
      t.timestamps
    end
    add_index :lms_glossary_terms, %i[course_id key], unique: true

    create_table :lms_assignment_rules do |t|
      t.string :tenant_id, null: false
      t.bigint :course_id, null: false
      t.string :role
      t.string :location_id
      t.boolean :required, null: false, default: false
      t.integer :due_days
      t.bigint :created_by_id
      t.timestamps
    end
    add_index :lms_assignment_rules, %i[tenant_id course_id]

    create_table :lms_enrollments do |t|
      t.string :tenant_id, null: false
      t.bigint :course_id, null: false
      t.bigint :user_id, null: false
      t.string :source, null: false, default: 'self'
      t.bigint :assignment_rule_id
      t.bigint :assigned_by_id
      t.boolean :required, null: false, default: false
      t.date :due_on
      t.string :status, null: false, default: 'assigned'
      t.datetime :started_at
      t.datetime :completed_at
      t.bigint :current_lesson_id
      t.datetime :badge_awarded_at
      t.timestamps
    end
    add_index :lms_enrollments, %i[course_id user_id], unique: true
    add_index :lms_enrollments, %i[tenant_id user_id status]

    create_table :lms_lesson_progresses do |t|
      t.string :tenant_id, null: false
      t.bigint :enrollment_id, null: false
      t.bigint :lesson_id, null: false
      t.bigint :user_id, null: false
      t.datetime :viewed_at
      t.datetime :passed_at
      t.integer :attempts, null: false, default: 0
      t.integer :best_score, null: false, default: 0
      t.timestamps
    end
    add_index :lms_lesson_progresses, %i[enrollment_id lesson_id], unique: true
    add_index :lms_lesson_progresses, %i[tenant_id user_id]

    create_table :lms_quiz_attempts do |t|
      t.string :tenant_id, null: false
      t.bigint :lesson_progress_id, null: false
      t.bigint :user_id, null: false
      t.text :answers_json, null: false
      t.integer :correct_count, null: false, default: 0
      t.integer :total_count, null: false, default: 0
      t.boolean :passed, null: false, default: false
      t.datetime :created_at, null: false
    end
    add_index :lms_quiz_attempts, %i[lesson_progress_id created_at]
  end
end
