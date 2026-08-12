class AddLastSlackSyncAtToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :last_slack_sync_at, :datetime
  end
end
