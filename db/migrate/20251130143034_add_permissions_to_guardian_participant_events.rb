class AddPermissionsToGuardianParticipantEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :guardian_participant_events, :photo_permission, :boolean
    add_column :guardian_participant_events, :media_permission, :boolean
    add_column :guardian_participant_events, :travel_permission, :boolean
  end
end
