class AddPublicProfileDetailsToParticipants < ActiveRecord::Migration[8.1]
  def change
    change_table :participants, bulk: true do |t|
      t.string :public_profile_location
      t.string :public_profile_website
      t.string :public_profile_github
      t.string :public_profile_twitter
      t.string :public_profile_linkedin
      t.string :public_profile_mastodon
      t.string :public_profile_bluesky
    end
  end
end
