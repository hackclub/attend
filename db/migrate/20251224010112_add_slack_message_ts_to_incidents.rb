class AddSlackMessageTsToIncidents < ActiveRecord::Migration[8.1]
  def change
    add_column :incidents, :slack_message_ts, :string
  end
end
