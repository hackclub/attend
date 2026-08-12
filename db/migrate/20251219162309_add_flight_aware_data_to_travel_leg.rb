class AddFlightAwareDataToTravelLeg < ActiveRecord::Migration[8.1]
  def change
    add_column :travel_legs, :flight_aware_data, :jsonb
  end
end
