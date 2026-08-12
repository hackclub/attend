class BackfillCheckInScans < ActiveRecord::Migration[8.1]
  # Check-in used to be recorded in two places that disagreed: a Scan in a
  # checks_in ScanContext (every scanner and the admin UI) and the
  # participant_events.checked_in_at column (only the MCP check_in tool). Scans
  # are now the single source of truth, so anyone who was only ever stamped in
  # the column needs a real scan before RemoveCheckedInAtFromParticipantEvents
  # can drop it.
  #
  # Idempotent: a row that already has a check-in scan is skipped, so this is
  # safe to re-run.
  BACKFILL_SOURCE = "backfill".freeze

  def up
    now = Time.current
    rows = []
    unattributed = []

    stamped_rows_without_check_in_scan.each do |row|
      user_id = attribution_user_id(row["id"], row["event_id"])
      if user_id.nil?
        unattributed << row["id"]
        next
      end

      rows << {
        participant_event_id: row["id"],
        scan_context_id: check_in_context_id(row["event_id"]),
        user_id: user_id,
        scanned_at: row["checked_in_at"],
        source: BACKFILL_SOURCE,
        created_at: now,
        updated_at: now
      }
    end

    # insert_all deliberately skips Scan's after_create_commit callback: each
    # save would broadcast to the event's live scan feed, and replaying old
    # check-ins onto today's scanner screens would be noise at best.
    Scan.insert_all(rows) if rows.any?

    say "Backfilled #{rows.size} check-in scan(s) from participant_events.checked_in_at"
    return if unattributed.empty?

    # scans.user_id is NOT NULL and there is no sensible user to invent, so these
    # are left alone — the drop migration refuses to run while any remain.
    say "WARNING: #{unattributed.size} stamped registration(s) had no user to attribute a " \
        "scan to and were skipped: #{unattributed.join(', ')}"
  end

  def down
    deleted = Scan.where(source: BACKFILL_SOURCE).delete_all
    say "Removed #{deleted} backfilled check-in scan(s)"
  end

  private

  # Raw SQL so this keeps working regardless of what the ParticipantEvent model
  # looks like by the time the migration runs.
  def stamped_rows_without_check_in_scan
    connection.select_all(<<~SQL.squish).to_a
      SELECT pe.id, pe.event_id, pe.checked_in_at
      FROM participant_events pe
      WHERE pe.checked_in_at IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM scans s
          JOIN scan_contexts sc ON sc.id = s.scan_context_id
          WHERE s.participant_event_id = pe.id AND sc.checks_in
        )
      ORDER BY pe.checked_in_at
    SQL
  end

  # Mirrors ParticipantEventsToolbox#check_in: the event's lowest-positioned
  # check-in context. Events that somehow have none get one, the same way
  # BackfillScanContexts did.
  def check_in_context_id(event_id)
    @check_in_context_ids ||= {}
    @check_in_context_ids[event_id] ||= begin
      existing = connection.select_value(<<~SQL.squish)
        SELECT id FROM scan_contexts
        WHERE event_id = #{connection.quote(event_id)} AND checks_in
        ORDER BY position NULLS LAST, created_at
        LIMIT 1
      SQL
      existing || create_check_in_context(event_id)
    end
  end

  def create_check_in_context(event_id)
    say "Event #{event_id} had no check-in scan context; creating \"Event check-in\""
    connection.select_value(<<~SQL.squish)
      INSERT INTO scan_contexts (event_id, name, checks_in, is_airport, position, created_at, updated_at)
      VALUES (#{connection.quote(event_id)}, 'Event check-in', TRUE, FALSE, 0, NOW(), NOW())
      RETURNING id
    SQL
  end

  # Best available actor, in descending order of how much it actually means:
  # whoever the audit log says stamped the column, then the event's admins, then
  # any of its staff, then the oldest global admin.
  def attribution_user_id(participant_event_id, event_id)
    audit_actor_id(participant_event_id) ||
      event_staff_user_id(event_id, role: "event_admin") ||
      event_staff_user_id(event_id) ||
      oldest_global_admin_id
  end

  def audit_actor_id(participant_event_id)
    # jsonb_exists rather than the ? operator, which Active Record would try to
    # read as a bind placeholder.
    connection.select_value(<<~SQL.squish)
      SELECT actor_user_id FROM audit_logs
      WHERE record_type = 'ParticipantEvent'
        AND record_id = #{connection.quote(participant_event_id)}
        AND actor_user_id IS NOT NULL
        AND jsonb_exists(changed_fields, 'checked_in_at')
      ORDER BY created_at
      LIMIT 1
    SQL
  end

  def event_staff_user_id(event_id, role: nil)
    @event_staff_ids ||= {}
    @event_staff_ids[[ event_id, role ]] ||= connection.select_value(<<~SQL.squish)
      SELECT user_id FROM event_role_assignments
      WHERE event_id = #{connection.quote(event_id)}
      #{"AND role = #{connection.quote(role)}" if role}
      ORDER BY created_at
      LIMIT 1
    SQL
  end

  def oldest_global_admin_id
    return @oldest_global_admin_id if defined?(@oldest_global_admin_id)

    @oldest_global_admin_id = connection.select_value(<<~SQL.squish)
      SELECT id FROM users WHERE global_role = 'global_admin' ORDER BY created_at LIMIT 1
    SQL
  end
end
