class AddEngagementPreferenceToParticipants < ActiveRecord::Migration[8.1]
  def change
    add_column :participants, :engagement_preference, :string
  end
end
