class AddVenueNameToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :venue_name, :string
  end
end
