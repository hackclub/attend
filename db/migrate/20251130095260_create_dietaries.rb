class CreateDietaries < ActiveRecord::Migration[8.0]
  def change
    create_table :dietaries, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :participant_event, null: false, foreign_key: true, type: :uuid, index: true
      t.string :diet_type
      t.text :intolerances
      t.text :life_threatening_allergies
      t.boolean :cross_contamination_risk, default: false
      t.text :notes

      t.timestamps
    end
  end
end
