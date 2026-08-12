class RemoveLumaColumns < ActiveRecord::Migration[8.1]
  def change
    remove_column :events, :luma_event_id, :string
    remove_column :events, :luma_api_key_encrypted, :text
    remove_column :participant_events, :luma_guest_id, :string
    remove_column :participant_events, :luma_sync_error, :jsonb
  end
end
