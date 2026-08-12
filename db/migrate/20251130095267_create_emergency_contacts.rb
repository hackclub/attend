class CreateEmergencyContacts < ActiveRecord::Migration[8.0]
  def change
    create_table :emergency_contacts, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :guardian_participant_event, type: :uuid, null: false, foreign_key: true, index: true
      t.string :name, null: false
      t.string :relationship
      t.string :phone, null: false
      t.string :email
      t.integer :priority, default: 1

      t.timestamps
    end
  end
end
