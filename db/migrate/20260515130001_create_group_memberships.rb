class CreateGroupMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :group_memberships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :group, type: :uuid, null: false, foreign_key: true
      t.references :participant_event, type: :uuid, null: false, foreign_key: true
      t.timestamps
    end

    add_index :group_memberships, [ :group_id, :participant_event_id ], unique: true, name: "idx_group_memberships_unique"
  end
end
