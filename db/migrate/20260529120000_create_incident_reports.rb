class CreateIncidentReports < ActiveRecord::Migration[8.1]
  def change
    create_table :incident_reports, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :event, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: true, foreign_key: true
      t.string :reporter_name, null: false
      t.string :reporter_email, null: false
      t.string :reporter_phone, null: false
      t.string :reporter_role, null: false
      t.string :incident_type, null: false
      t.string :priority, null: false
      t.text :summary, null: false
      t.text :details, null: false
      t.string :status, null: false, default: "open"
      t.timestamps
    end

    add_index :incident_reports, :status
    add_index :incident_reports, :priority
    add_index :incident_reports, :created_at
  end
end
