class AddUmVerificationToParticipantEvents < ActiveRecord::Migration[8.0]
  def change
    add_column :participant_events, :um_status, :string, default: "none", null: false
    add_column :participant_events, :um_verified_at, :datetime
    add_column :participant_events, :um_guardian_confirmed_at, :datetime
    add_column :participant_events, :um_review_requested_at, :datetime
    add_reference :participant_events, :um_verified_by, type: :uuid, foreign_key: { to_table: :users }
    add_index :participant_events, :um_status
  end
end
