class AddPlaceIdsToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :apple_place_id, :string
    add_column :events, :google_place_id, :string
  end
end
