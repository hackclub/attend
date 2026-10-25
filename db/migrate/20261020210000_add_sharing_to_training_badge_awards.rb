class AddSharingToTrainingBadgeAwards < ActiveRecord::Migration[8.1]
  def change
    # Set when the holder turns on sharing: the unguessable part of the public
    # /verify link. Cleared when they turn it off, which kills the link.
    add_column :training_badge_awards, :share_token, :string
    add_column :training_badge_awards, :shared_at, :datetime
    add_index :training_badge_awards, :share_token, unique: true
  end
end
