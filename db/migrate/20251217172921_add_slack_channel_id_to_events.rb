class AddSlackChannelIdToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :slack_channel_id, :string
  end
end
