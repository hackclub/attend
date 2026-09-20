class AddArrivalWindowToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :arrival_opens_at, :datetime
    add_column :events, :arrival_closes_at, :datetime
  end
end
