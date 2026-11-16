# For records a registration's requirements are read from (travel, health,
# consents, guardians). Any committed change re-derives the status of the
# registration it belongs to, so the status column can't fall behind.
#
#   include SyncsRegistration
#   syncs_registration cause: :data_changed
#
# Override #registration_ids_to_sync when the record isn't a direct child of
# one registration, and #registration_sync_cause when the change itself says
# something more specific (a consent becoming signed, a guardian finishing).
# The sync on commit is the one that moves the status, so the cause it
# records is the one the history shows.
module SyncsRegistration
  extend ActiveSupport::Concern

  # Skips the per-record sync inside the block, for code that writes several
  # of a registration's records in one go and leaves its status right itself.
  def self.suspended
    previous = ActiveSupport::IsolatedExecutionState[:registration_sync_suspended]
    ActiveSupport::IsolatedExecutionState[:registration_sync_suspended] = true
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[:registration_sync_suspended] = previous
  end

  def self.suspended?
    ActiveSupport::IsolatedExecutionState[:registration_sync_suspended] == true
  end

  included do
    class_attribute :default_registration_sync_cause, instance_writer: false
  end

  class_methods do
    def syncs_registration(cause:, **options)
      self.default_registration_sync_cause = cause
      after_commit :sync_registration_status, **options
    end
  end

  def registration_ids_to_sync
    [ participant_event_id ]
  end

  def registration_sync_cause
    default_registration_sync_cause
  end

  private

  # Looked up fresh rather than through the association: the registration may
  # have been destroyed along with this record, and a cached copy would hold
  # associations as they were before this change.
  def sync_registration_status
    return if SyncsRegistration.suspended?

    ParticipantEvent.where(id: registration_ids_to_sync.compact).find_each do |participant_event|
      participant_event.sync_status!(cause: registration_sync_cause)
    end
  end
end
