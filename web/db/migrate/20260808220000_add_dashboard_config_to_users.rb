class AddDashboardConfigToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :dashboard_config, :text
  end
end
