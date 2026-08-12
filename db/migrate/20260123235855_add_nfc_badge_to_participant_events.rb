class AddNfcBadgeToParticipantEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :participant_events, :nfc_badge_token, :uuid
    add_index :participant_events, :nfc_badge_token, unique: true
    add_column :participant_events, :nfc_badge_assigned_at, :datetime
    add_column :participant_events, :nfc_badge_assigned_by_id, :uuid
    add_foreign_key :participant_events, :users, column: :nfc_badge_assigned_by_id
  end
end
