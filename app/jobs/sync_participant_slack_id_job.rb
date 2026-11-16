# Copies the Slack id from an account's last sign-in onto a participant linked
# to it. Queued by the admin participant page when it notices the two differ,
# so that viewing the page doesn't write.
#
# Takes the participant, not the user: the page shows the id on the row it is
# looking at, and that is the row that has to end up with it.
class SyncParticipantSlackIdJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(participant)
    participant.user&.sync_slack_id_to_participant(participant)
  end
end
