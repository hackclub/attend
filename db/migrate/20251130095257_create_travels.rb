class CreateTravels < ActiveRecord::Migration[8.0]
  def change
    create_table :travels, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :participant_event, null: false, foreign_key: true, type: :uuid, index: true
      t.string :direction, null: false
      t.string :mode
      t.string :carrier
      t.string :flight_number
      t.string :departure_city
      t.string :departure_station
      t.string :arrival_city
      t.string :arrival_station
      t.datetime :departure_time
      t.datetime :arrival_time
      t.boolean :is_unaccompanied_minor, default: false
      t.string :passport_nationality
      t.boolean :visa_required, default: false
      t.string :visa_status
      t.string :visa_type
      t.string :visa_number
      t.text :notes

      t.timestamps
    end
  end
end
