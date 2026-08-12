class RemoveCheckedInAtFromParticipantEvents < ActiveRecord::Migration[8.1]
  # Scans in a checks_in ScanContext are now the only record of check-in
  # (ParticipantEvent#check_in_time). BackfillCheckInScans turns any
  # column-only check-in into a real scan first.
  def up
    stranded = connection.select_value(<<~SQL.squish)
      SELECT COUNT(*)
      FROM participant_events pe
      WHERE pe.checked_in_at IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM scans s
          JOIN scan_contexts sc ON sc.id = s.scan_context_id
          WHERE s.participant_event_id = pe.id AND sc.checks_in
        )
    SQL

    if stranded.to_i.positive?
      raise ActiveRecord::IrreversibleMigration,
        "#{stranded} participant_event(s) still have checked_in_at set with no check-in scan. " \
        "Dropping the column would lose those check-ins — see BackfillCheckInScans's skipped " \
        "rows (they had no user to attribute a scan to) and give them a scan first."
    end

    remove_column :participant_events, :checked_in_at
  end

  def down
    add_column :participant_events, :checked_in_at, :datetime

    # Repopulate from scans so code that reads the column works again.
    execute <<~SQL.squish
      UPDATE participant_events pe
      SET checked_in_at = first_scans.scanned_at
      FROM (
        SELECT s.participant_event_id, MIN(s.scanned_at) AS scanned_at
        FROM scans s
        JOIN scan_contexts sc ON sc.id = s.scan_context_id
        WHERE sc.checks_in
        GROUP BY s.participant_event_id
      ) AS first_scans
      WHERE pe.id = first_scans.participant_event_id
    SQL
  end
end
