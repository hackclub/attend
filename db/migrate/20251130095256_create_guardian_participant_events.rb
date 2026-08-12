class CreateGuardianParticipantEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :guardian_participant_events, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :guardian, null: false, foreign_key: true, type: :uuid
      t.references :participant_event, null: false, foreign_key: true, type: :uuid
      t.string :relationship
      t.boolean :is_primary_guardian, default: false
      t.integer :emergency_contact_priority
      t.string :phone_override
      t.string :airtable_record_id
      t.string :invite_token_digest
      t.datetime :invite_token_sent_at
      t.string :invited_via_email
      t.datetime :accepted_at
      t.string :status, default: "pending"
      t.boolean :emergency_medical_consent
      t.boolean :otc_medication_consent

      t.timestamps
    end

    add_index :guardian_participant_events, :invite_token_digest
    add_index :guardian_participant_events, [ :guardian_id, :participant_event_id ], unique: true, name: "index_guardian_participant_events_uniqueness"
  end
end
