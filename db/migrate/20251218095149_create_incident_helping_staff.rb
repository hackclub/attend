class CreateIncidentHelpingStaff < ActiveRecord::Migration[8.0]
  def change
    create_table :incident_helping_staff, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :incident, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true

      t.timestamps
    end

    add_index :incident_helping_staff, [ :incident_id, :user_id ], unique: true, name: "idx_incident_helping_staff_unique"
  end
end
