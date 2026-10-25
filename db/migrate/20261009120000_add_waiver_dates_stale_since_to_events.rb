class AddWaiverDatesStaleSinceToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :waiver_dates_stale_since, :datetime
  end
end
