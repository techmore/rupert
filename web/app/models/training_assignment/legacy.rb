# frozen_string_literal: true

class TrainingAssignment
  # The original training_assignments table (#521), kept read-only for one release after its rows were copied into the
  # shared work-item table (migration 20261026150900). Read only to send old /employee/training/:id links to the new
  # id (`work_item_id`). Drop it, and this class, in a later pull request once the copy is verified in production.
  class Legacy < ApplicationRecord
    include TenantScoped

    self.table_name = 'training_assignments'

    def readonly? = true

    # The new id of the old assignment `id`, when it belongs to `user` (nil otherwise).
    def self.work_item_id_for(id, user)
      where(id: id.to_s, assignee_id: user.id).where.not(work_item_id: nil).pick(:work_item_id)
    end
  end
end
