class AddCompletedAtToGuardianParticipantEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :guardian_participant_events, :completed_at, :datetime
  end
end
