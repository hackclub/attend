class AddPublicProfileToParticipants < ActiveRecord::Migration[8.1]
  def change
    add_column :participants, :public_profile_enabled, :boolean, default: false, null: false
    add_column :participants, :public_profile_slug, :string
    add_column :participants, :public_profile_bio, :text
    add_column :participants, :public_profile_show_photo, :boolean, default: false, null: false
    add_index :participants, :public_profile_slug, unique: true

    add_column :participant_events, :hidden_from_public_profile, :boolean, default: false, null: false
  end
end
