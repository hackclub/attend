class AddSlackUserIdToParticipants < ActiveRecord::Migration[8.1]
  def change
    add_column :participants, :slack_user_id, :string

    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE participants
          SET slack_user_id = (
            SELECT participant_events.slack_user_id
            FROM participant_events
            WHERE participant_events.participant_id = participants.id
              AND participant_events.slack_user_id IS NOT NULL
              AND participant_events.slack_user_id != ''
            ORDER BY participant_events.created_at DESC
            LIMIT 1
          )
        SQL
      end
    end
  end
end
