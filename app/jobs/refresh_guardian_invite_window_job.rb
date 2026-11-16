# Reopens the window on a guardian portal link that staff were just shown on
# the admin participant page, so the link they copy works when it's opened.
# See GuardianParticipantEvent#refresh_stale_invite_window!.
class RefreshGuardianInviteWindowJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(guardian_participant_event)
    guardian_participant_event.refresh_stale_invite_window!
  end
end
