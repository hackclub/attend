class AddSlackMessageFieldsToIncidentReports < ActiveRecord::Migration[8.1]
  def change
    add_column :incident_reports, :slack_message_ts, :string
    add_column :incident_reports, :slack_channel_id, :string
  end
end
