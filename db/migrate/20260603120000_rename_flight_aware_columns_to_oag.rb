class RenameFlightAwareColumnsToOag < ActiveRecord::Migration[8.0]
  def change
    rename_column :travel_legs, :flight_aware_id, :oag_schedule_instance_key
    rename_column :travel_legs, :flight_aware_data, :oag_flight_data

    # Stored values come from FlightAware and are not valid OAG identifiers —
    # next refresh will repopulate via OAG.
    reversible do |dir|
      dir.up do
        execute "UPDATE travel_legs SET oag_schedule_instance_key = NULL, oag_flight_data = NULL, last_tracked_at = NULL"
      end
    end
  end
end
