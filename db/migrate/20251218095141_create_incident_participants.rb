class CreateIncidentParticipants < ActiveRecord::Migration[8.0]
  def change
    create_table :incident_participants, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :incident, type: :uuid, null: false, foreign_key: true
      t.references :participant_event, type: :uuid, null: false, foreign_key: true

      t.timestamps
    end

    add_index :incident_participants, [ :incident_id, :participant_event_id ], unique: true, name: "idx_incident_participants_unique"
  end
end
