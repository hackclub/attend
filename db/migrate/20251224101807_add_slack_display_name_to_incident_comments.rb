class AddSlackDisplayNameToIncidentComments < ActiveRecord::Migration[8.1]
  def change
    add_column :incident_comments, :slack_display_name, :string
  end
end
