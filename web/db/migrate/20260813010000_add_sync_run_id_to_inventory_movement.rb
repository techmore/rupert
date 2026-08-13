# frozen_string_literal: true

class AddSyncRunIdToInventoryMovement < ActiveRecord::Migration[8.1]
  def change
    add_column :"InventoryMovement", :syncRunId, :string
    add_index :"InventoryMovement", :syncRunId
  end
end
