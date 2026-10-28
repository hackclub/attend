# Each stay gets its own lodging scan point, so arrivals at the hotel for the
# night before (say) are counted against the people with a room that night,
# not the whole event. One scan point belongs to at most one stay.
#
# A stay during the event adopts the event's existing hotel scan point when
# there is one. Other existing stays get a scan point when an organizer asks
# for one, rather than every past event growing a new one here.
class LinkRoomingContextsToScanContexts < ActiveRecord::Migration[8.1]
  def up
    add_reference :rooming_contexts, :scan_context, type: :uuid,
      foreign_key: { on_delete: :nullify }, index: { unique: true }

    execute <<~SQL.squish
      UPDATE rooming_contexts SET scan_context_id = events.hotel_scan_context_id
      FROM events
      WHERE rooming_contexts.event_id = events.id
        AND rooming_contexts.kind = 'main'
        AND events.hotel_scan_context_id IS NOT NULL
        AND rooming_contexts.scan_context_id IS NULL
    SQL
  end

  def down
    remove_reference :rooming_contexts, :scan_context, foreign_key: true, index: true
  end
end
