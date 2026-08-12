class AddFlightTrackingToTravelLegs < ActiveRecord::Migration[8.1]
  def change
    add_column :travel_legs, :live_status, :string
    add_column :travel_legs, :live_departure_time, :datetime
    add_column :travel_legs, :live_arrival_time, :datetime
    add_column :travel_legs, :live_data, :jsonb
    add_column :travel_legs, :last_tracked_at, :datetime
  end
end
