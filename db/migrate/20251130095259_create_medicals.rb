class CreateMedicals < ActiveRecord::Migration[8.0]
  def change
    create_table :medicals, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :participant_event, type: :uuid, null: false, foreign_key: true, index: true
      t.text :allergies
      t.string :allergy_severity
      t.boolean :has_anaphylaxis_risk, default: false
      t.text :medical_conditions
      t.text :medications
      t.boolean :requires_refrigeration, default: false
      t.text :emergency_action_plan
      t.text :additional_notes
      t.references :last_updated_by_user, type: :uuid, foreign_key: { to_table: :users }

      t.timestamps
    end
  end
end
