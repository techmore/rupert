# frozen_string_literal: true

namespace :training do
  desc 'Copy training assignments the previous release wrote to the old tables into the shared work-item table (#409)'
  task copy_legacy_assignments: :environment do
    # The copy is the one the migration ran: idempotent, and it stops (saving nothing) if the counts do not match.
    require Rails.root.join('db/migrate/20261026150900_move_training_assignments_to_work_items').to_s
    result = MoveTrainingAssignmentsToWorkItems::Copy.run!(ActiveRecord::Base.connection)
    puts "Copied #{result[:assignments]} assignment(s) and #{result[:events]} history row(s); brought #{result[:refreshed]} copy(ies) up to date. Counts match."
  end
end
