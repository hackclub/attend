# Writes the audit log entry for someone opening a sensitive record (see
# AuditLog.log_view_later), so the page view itself stays a read.
#
# Takes ids rather than records: the entry must still be written if the
# record is gone by the time this runs.
class AuditViewJob < ApplicationJob
  queue_as :default

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
