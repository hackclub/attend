class AddOnboardingCompletedAtToParticipantEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :participant_events, :onboarding_completed_at, :datetime
  end
end
