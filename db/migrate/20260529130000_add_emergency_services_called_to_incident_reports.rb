class AddEmergencyServicesCalledToIncidentReports < ActiveRecord::Migration[8.1]
  def change
    add_column :incident_reports, :emergency_services_called, :boolean
  end
end
