class AddAirtableSyncPauseToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :airtable_sync_paused_at, :datetime
    add_reference :events, :airtable_config_updated_by, type: :uuid, null: true, foreign_key: { to_table: :users }
  end
end
