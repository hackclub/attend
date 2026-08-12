class CreateParticipantEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :participant_events, id: :uuid, default: "gen_random_uuid()" do |t|
      t.uuid :participant_id, null: false
      t.uuid :event_id, null: false
      t.string :status, null: false, default: "invited"
      t.integer :onboarding_step, default: 0
      t.jsonb :onboarding_payload, default: {}
      t.string :luma_guest_id
      t.jsonb :luma_sync_error
      t.string :airtable_record_id
      t.datetime :checked_in_at

      t.timestamps
    end

    add_index :participant_events, :participant_id
    add_index :participant_events, :event_id
    add_index :participant_events, :status
    add_index :participant_events, [ :participant_id, :event_id ], unique: true

    add_foreign_key :participant_events, :participants
    add_foreign_key :participant_events, :events
  end
end
