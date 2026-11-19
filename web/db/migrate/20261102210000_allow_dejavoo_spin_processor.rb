# frozen_string_literal: true

# Dejavoo SPIn terminals (via Valmar) get their own processor-approved product
# list, separate from Authorize.net, NMI and the standalone terminal.
class AllowDejavooSpinProcessor < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :processor_catalogs, name: 'processor_catalog_processor'
    add_check_constraint :processor_catalogs, "processor IN ('authorize_net', 'nmi', 'card_terminal', 'dejavoo_spin')", name: 'processor_catalog_processor'
  end

  def down
    execute "DELETE FROM processor_catalog_entries WHERE processor_catalog_id IN (SELECT id FROM processor_catalogs WHERE processor = 'dejavoo_spin')"
    execute "DELETE FROM processor_catalogs WHERE processor = 'dejavoo_spin'"
    remove_check_constraint :processor_catalogs, name: 'processor_catalog_processor'
    add_check_constraint :processor_catalogs, "processor IN ('authorize_net', 'nmi', 'card_terminal')", name: 'processor_catalog_processor'
  end
end
