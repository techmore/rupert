class CreateProjectsGoalsKpis < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :tenant_id, null: false
      t.string :name, null: false
      t.text :description
      t.string :status, default: "planned", null: false
      t.string :owner_id
      t.date :due_on
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index [:tenant_id, :status]
      t.index [:tenant_id, :owner_id]
    end

    create_table :tasks do |t|
      t.string :tenant_id, null: false
      t.string :project_id
      t.string :title, null: false
      t.text :description
      t.string :status, default: "todo", null: false
      t.string :assignee_id
      t.string :priority, default: "medium"
      t.date :due_on
      t.datetime :completed_at
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index [:tenant_id, :status]
      t.index [:tenant_id, :project_id]
      t.index [:tenant_id, :assignee_id]
    end

    create_table :goals do |t|
      t.string :tenant_id, null: false
      t.string :name, null: false
      t.text :description
      t.string :status, default: "active", null: false
      t.string :unit
      t.decimal :target_value, precision: 12, scale: 2
      t.decimal :current_value, precision: 12, scale: 2, default: 0
      t.date :due_on
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index [:tenant_id, :status]
    end

    create_table :kpis do |t|
      t.string :tenant_id, null: false
      t.string :name, null: false
      t.string :unit
      t.decimal :target_value, precision: 12, scale: 2
      t.string :direction, default: "up", null: false
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index [:tenant_id, :name]
    end

    create_table :kpi_readings do |t|
      t.string :tenant_id, null: false
      t.string :kpi_id, null: false
      t.decimal :value, precision: 12, scale: 2, null: false
      t.datetime :measured_at, null: false
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index [:tenant_id, :kpi_id, :measured_at]
    end
  end
end
