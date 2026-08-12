class CreateScanContexts < ActiveRecord::Migration[8.1]
  def change
    create_table :scan_contexts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid

      t.string :name, null: false
      t.boolean :checks_in, null: false, default: true
      t.boolean :is_airport, null: false, default: false
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :scan_contexts, [ :event_id, :position ]
  end
end
