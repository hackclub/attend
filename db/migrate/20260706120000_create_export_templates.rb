class CreateExportTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :export_templates, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :event, type: :uuid, null: false, foreign_key: true
      t.references :created_by, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.jsonb :columns, null: false, default: []
      t.jsonb :filters, null: false, default: []
      t.string :row_mode, null: false, default: "participant"
      t.timestamps
    end

    add_index :export_templates, [ :event_id, :name ], unique: true
  end
end
