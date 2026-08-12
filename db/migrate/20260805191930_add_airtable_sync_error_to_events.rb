class AddAirtableSyncErrorToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :airtable_sync_error, :text
    add_column :events, :airtable_sync_error_at, :datetime
  end
end
