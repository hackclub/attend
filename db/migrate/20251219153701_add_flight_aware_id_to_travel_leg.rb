class AddFlightAwareIdToTravelLeg < ActiveRecord::Migration[8.1]
  def change
    add_column :travel_legs, :flight_aware_id, :string
  end
end
