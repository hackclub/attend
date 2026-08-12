class AddCustomEventToIncidentReports < ActiveRecord::Migration[8.1]
  def change
    add_column :incident_reports, :custom_event_name, :string
    change_column_null :incident_reports, :event_id, true
  end
end
