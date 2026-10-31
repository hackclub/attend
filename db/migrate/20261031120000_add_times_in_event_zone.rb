# Typed times on these tables used to be stored as UTC wall-clock. Existing
# rows keep that reading (false) and keep rendering on UTC; rows saved by
# EventLocalTimes are on the event's clock (the model defaults new rows to
# true, so the column default stays false for anything written around it).
class AddTimesInEventZone < ActiveRecord::Migration[8.1]
  def change
    %i[scan_contexts incidents travels].each do |table|
      add_column table, :times_in_event_zone, :boolean, null: false, default: false
    end
  end
end
