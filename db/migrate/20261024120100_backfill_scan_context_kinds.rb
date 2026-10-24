# Gives every existing scan point a kind from the flags it already has. Only
# kind is written; checks_in, is_travel_pickup and events.hotel_scan_context_id
# are read, never changed. Earlier rules win:
#   the event's hotel scan point   -> lodging
#   is_travel_pickup               -> pickup (travel calendar shows Collected first)
#   checks_in                      -> venue
#   anything else                  -> tracking_only
# Only rows with no kind yet are touched, so re-running it is safe.
class BackfillScanContextKinds < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE scan_contexts SET kind = CASE
        WHEN EXISTS (SELECT 1 FROM events WHERE events.hotel_scan_context_id = scan_contexts.id) THEN 'lodging'
        WHEN is_travel_pickup THEN 'pickup'
        WHEN checks_in THEN 'venue'
        ELSE 'tracking_only'
      END
      WHERE kind IS NULL
    SQL
  end

  def down
    execute "UPDATE scan_contexts SET kind = NULL"
  end
end
