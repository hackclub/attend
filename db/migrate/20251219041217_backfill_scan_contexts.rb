class BackfillScanContexts < ActiveRecord::Migration[8.1]
  def up
    Event.find_each do |event|
      default_context = event.scan_contexts.find_by(checks_in: true) ||
                        event.scan_contexts.create!(
                          name: "Event check-in",
                          checks_in: true,
                          is_airport: false,
                          position: 0
                        )

      Scan.joins(:participant_event)
          .where(scan_context_id: nil, participant_events: { event_id: event.id })
          .update_all(scan_context_id: default_context.id)
    end
  end

  def down
    Scan.update_all(scan_context_id: nil)
    ScanContext.delete_all
  end
end
