# frozen_string_literal: true

# The Learning center: courses, lessons, quizzes, glossary, assignments and progress.
# Content is data (seeded from db/seeds/lms, editable by people with hr.write); visuals
# (diagrams) are view partials referenced by key. See docs/lms/README.md.
module Lms
  def self.table_name_prefix = 'lms_'

  LEARNER_PERMISSION = nil        # every signed-in, active account can learn
  TEAM_PERMISSION = 'hr.read'     # see team completion
  EDIT_PERMISSION = 'hr.write'    # edit courses, assign them
end
