class AddAccessibilityNeedsAndNotesToAccommodations < ActiveRecord::Migration[8.1]
  def change
    add_column :accommodations, :accessibility_needs, :text
    add_column :accommodations, :notes, :text
  end
end
