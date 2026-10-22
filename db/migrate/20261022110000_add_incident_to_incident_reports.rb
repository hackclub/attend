class AddIncidentToIncidentReports < ActiveRecord::Migration[8.1]
  def change
    add_reference :incident_reports, :incident, type: :uuid, null: true,
      index: { unique: true }, foreign_key: { on_delete: :nullify }
  end
end
