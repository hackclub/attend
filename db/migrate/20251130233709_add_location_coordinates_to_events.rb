class AddLocationCoordinatesToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :location_latitude, :decimal, precision: 10, scale: 6
    add_column :events, :location_longitude, :decimal, precision: 10, scale: 6
    add_column :events, :location_address, :string
  end
end
