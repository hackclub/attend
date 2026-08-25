class RenameAirportPickupToTravelPickup < ActiveRecord::Migration[8.1]
  def change
    rename_column :scan_contexts, :is_airport, :is_travel_pickup
    rename_column :travel_legs, :airport_picked_up_at, :travel_picked_up_at
  end
end
