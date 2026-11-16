# Writes the audit log entry for someone opening a sensitive record (see
# AuditLog.log_view_later), so the page view itself stays a read.
#
# Takes ids rather than records: the entry must still be written if the
# record is gone by the time this runs.
class AuditViewJob < ApplicationJob
  queue_as :default

  # The page has already been served by the time this runs, so nothing else
  # will write the entry if this gives up. A database blip (the primary
  # restarting, a failover) must not cost the record of who looked at what:
  # keep trying for a few hours before landing in the failed jobs. The entry
  # is only ever written by the attempt that succeeds, so a retry can't
  # double it.
  retry_on StandardError, wait: :polynomially_longer, attempts: 10

  def perform(record_type:, record_id:, actor_user_id:, viewed_at:, event_id: nil, metadata: {})
    AuditLog.create!(
      action: :view,
      record_type: record_type,
      record_id: record_id,
      actor_user_id: actor_user_id,
      event_id: event_id,
      metadata: metadata,
      created_at: viewed_at
    )
  end
end
