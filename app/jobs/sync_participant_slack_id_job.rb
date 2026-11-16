# Copies the Slack id from an account's last sign-in onto a participant linked
# to it. Queued by the admin participant page when it notices the two differ,
# so that viewing the page doesn't write.
#
# Takes the participant, not the user: the page shows the id on the row it is
# looking at, and that is the row that has to end up with it.
class SyncParticipantSlackIdJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  # The page queues this on every view until the id is saved: reloads, a
  # second admin, link prefetches. One job per participant per interval is
  # plenty, and it also caps a job that keeps failing at one new failure per
  # interval instead of one per page view.
  ENQUEUE_INTERVAL = 10.minutes

  def self.perform_later_once(participant)
    first = Rails.cache.write("sync_participant_slack_id/#{participant.id}", true,
      unless_exist: true, expires_in: ENQUEUE_INTERVAL)

    perform_later(participant) if first
  end

  def perform(participant)
    participant.user&.sync_slack_id_to_participant(participant)
  end
end
