class AddSlackAvatarUrlToIncidentComments < ActiveRecord::Migration[8.1]
  def change
    add_column :incident_comments, :slack_avatar_url, :string
  end
end
