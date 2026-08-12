class AddPickupDismissedAtToTravels < ActiveRecord::Migration[8.1]
  def change
    add_column :travels, :pickup_dismissed_at, :datetime
  end
end
