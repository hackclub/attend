class AddSlackFieldsToIncidentComments < ActiveRecord::Migration[8.1]
  def change
    add_column :incident_comments, :slack_message_ts, :string
    add_column :incident_comments, :slack_channel_id, :string
    add_column :incident_comments, :slack_user_id, :string
    add_column :incident_comments, :source, :string
  end
end
