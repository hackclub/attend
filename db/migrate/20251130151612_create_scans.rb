class CreateScans < ActiveRecord::Migration[8.1]
  def change
    create_table :scans, id: :uuid do |t|
      t.references :participant_event, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.datetime :scanned_at, null: false

      t.timestamps
    end

    add_index :scans, [ :participant_event_id, :scanned_at ]
  end
end
