class AddStaffNamesToRooms < ActiveRecord::Migration[8.1]
  def change
    add_column :rooms, :staff_names, :text
  end
end
