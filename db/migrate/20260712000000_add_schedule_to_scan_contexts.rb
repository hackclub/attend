class AddScheduleToScanContexts < ActiveRecord::Migration[8.1]
  def change
    add_column :scan_contexts, :starts_at, :datetime
    add_column :scan_contexts, :ends_at, :datetime
  end
end
