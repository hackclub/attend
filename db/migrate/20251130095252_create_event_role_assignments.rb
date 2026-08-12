class CreateEventRoleAssignments < ActiveRecord::Migration[8.0]
  def change
    create_table :event_role_assignments, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :event, null: false, foreign_key: true, type: :uuid
      t.string :role, null: false

      t.timestamps
    end

    add_index :event_role_assignments, [ :user_id, :event_id, :role ], unique: true
  end
end
