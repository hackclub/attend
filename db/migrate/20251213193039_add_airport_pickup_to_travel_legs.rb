class AddAirportPickupToTravelLegs < ActiveRecord::Migration[8.1]
  def change
    add_column :travel_legs, :airport_picked_up_at, :datetime
    add_column :travel_legs, :picked_up_by_user_id, :uuid
    add_index :travel_legs, :picked_up_by_user_id
  end
end
