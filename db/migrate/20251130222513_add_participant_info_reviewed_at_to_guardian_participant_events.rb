class AddParticipantInfoReviewedAtToGuardianParticipantEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :guardian_participant_events, :participant_info_reviewed_at, :datetime
  end
end
