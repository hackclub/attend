class AddParticipantEventToEmergencyContacts < ActiveRecord::Migration[8.1]
  def up
    add_reference :emergency_contacts, :participant_event, type: :uuid, foreign_key: true

    change_column_null :emergency_contacts, :guardian_participant_event_id, true

    say_with_time "Backfilling emergency_contacts.participant_event_id" do
      execute <<~SQL
        UPDATE emergency_contacts ec
        SET participant_event_id = gpe.participant_event_id
        FROM guardian_participant_events gpe
        WHERE ec.guardian_participant_event_id = gpe.id
      SQL
    end
  end

  def down
    remove_reference :emergency_contacts, :participant_event

    change_column_null :emergency_contacts, :guardian_participant_event_id, false
  end
end
