class AddEngagementNotesToParticipants < ActiveRecord::Migration[8.1]
  def change
    add_column :participants, :engagement_notes, :text
  end
end
