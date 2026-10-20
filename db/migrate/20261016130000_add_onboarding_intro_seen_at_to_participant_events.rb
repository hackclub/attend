class AddOnboardingIntroSeenAtToParticipantEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :participant_events, :onboarding_intro_seen_at, :datetime
  end
end
