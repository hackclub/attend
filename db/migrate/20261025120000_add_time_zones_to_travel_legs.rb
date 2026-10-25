# Each flight leg endpoint remembers the zone its wall-clock time was entered
# in, so it can be shown back in that zone and re-edited without shifting.
class AddTimeZonesToTravelLegs < ActiveRecord::Migration[8.1]
  def change
    add_column :travel_legs, :departure_time_zone, :string
    add_column :travel_legs, :arrival_time_zone, :string
  end
end
