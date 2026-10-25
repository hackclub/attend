class CreateIncidentMedications < ActiveRecord::Migration[8.1]
  def change
    add_column :incidents, :medication_dispensed, :boolean, default: false, null: false

    create_table :incident_medications, id: :uuid do |t|
      t.references :incident, null: false, foreign_key: true, type: :uuid
      t.text :name, null: false
      t.text :dose, null: false
      t.text :notes

      t.timestamps
    end
  end
end
