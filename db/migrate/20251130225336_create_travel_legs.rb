class CreateTravelLegs < ActiveRecord::Migration[8.1]
  def change
    create_table :travel_legs, id: :uuid do |t|
      t.references :travel, null: false, foreign_key: true, type: :uuid
      t.integer :position, default: 0
      t.string :flight_code
      t.string :departure_airport
      t.string :arrival_airport
      t.datetime :departure_time
      t.datetime :arrival_time
      t.string :confirmation_code

      t.timestamps
    end
  end
end
