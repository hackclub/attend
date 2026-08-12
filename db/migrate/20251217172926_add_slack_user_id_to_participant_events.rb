class AddSlackUserIdToParticipantEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :participant_events, :slack_user_id, :string
  end
end
