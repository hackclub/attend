class CreateNotes < ActiveRecord::Migration[8.0]
  def change
    create_table :notes, id: :uuid, default: "gen_random_uuid()" do |t|
      t.uuid :event_id, null: false
      t.uuid :participant_event_id
      t.uuid :author_user_id, null: false
      t.string :note_type
      t.text :body
      t.string :sensitivity, default: "normal"
      t.string :visible_to_roles, array: true, default: []

      t.timestamps
    end

    add_index :notes, :event_id
    add_foreign_key :notes, :events
    add_foreign_key :notes, :participant_events
    add_foreign_key :notes, :users, column: :author_user_id
  end
end
