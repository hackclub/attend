# Copies the Slack id from a user's last sign-in onto their participant.
# Queued by the admin participant page when it notices the two differ, so
# that viewing the page doesn't write.
class SyncParticipantSlackIdJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(user)
    user.sync_slack_id_to_participant
  end
end
