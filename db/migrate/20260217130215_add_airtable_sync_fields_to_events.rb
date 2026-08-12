class AddAirtableSyncFieldsToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :airtable_sync_source_id, :string
    add_column :events, :airtable_sync_table_id, :string
    add_column :events, :airtable_synced_at, :datetime
  end
end
