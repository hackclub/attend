class AddRoomingExemptToAccommodations < ActiveRecord::Migration[8.1]
  def change
    add_column :accommodations, :rooming_exempt, :boolean, default: false, null: false
  end
end
