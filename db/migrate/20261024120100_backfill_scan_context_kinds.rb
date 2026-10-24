# Gives every existing scan point a kind from the flags it already has. Only
# kind is written; checks_in, is_travel_pickup and events.hotel_scan_context_id
# are read, never changed. The flags decide first, so a kind never contradicts
# what a point already does:
#   checks_in                                  -> venue
#   is_travel_pickup                           -> pickup
#   its own event's hotel scan point           -> lodging
#   anything else                              -> tracking_only
# Only rows with no kind yet are touched, so re-running it is safe.
class BackfillScanContextKinds < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE scan_contexts SET kind = CASE
        WHEN checks_in THEN 'venue'
        WHEN is_travel_pickup THEN 'pickup'
        WHEN EXISTS (
          SELECT 1 FROM events
          WHERE events.id = scan_contexts.event_id AND events.hotel_scan_context_id = scan_contexts.id
        ) THEN 'lodging'
        ELSE 'tracking_only'
      END
      WHERE kind IS NULL
    SQL
  end

  # Kinds chosen after the backfill can't be derived again, so rolling this
  # back keeps them; rolling back the column migration drops the column.
  def down; end
end
