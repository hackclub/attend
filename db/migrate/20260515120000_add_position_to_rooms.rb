class AddPositionToRooms < ActiveRecord::Migration[8.1]
  def change
    add_column :rooms, :position, :integer
    add_index :rooms, [ :event_id, :position ]
  end
end
