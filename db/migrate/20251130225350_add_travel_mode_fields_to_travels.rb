class AddTravelModeFieldsToTravels < ActiveRecord::Migration[8.1]
  def change
    add_column :travels, :origin_address, :text
    add_column :travels, :expected_arrival_time, :datetime
    add_column :travels, :other_details, :text
    add_column :travels, :bus_departure_location, :string
    add_column :travels, :bus_arrival_location, :string
    add_column :travels, :train_departure_station, :string
    add_column :travels, :train_arrival_station, :string
  end
end
