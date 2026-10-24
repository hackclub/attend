# Adds one completed participant to their event's Slack channel. Enqueued when
# a registration becomes complete and when a participant's Slack ID changes, so
# people no longer wait for an admin to press "Sync Slack channel" (which runs
# SyncSlackChannelJob for the whole event).
#
# Safe to run more than once: Slack answers already_in_channel for a member,
# which SlackService treats as success.
class InviteToEventSlackChannelJob < ApplicationJob
  queue_as :default

  retry_on SlackService::RateLimited, wait: 1.minute, attempts: 5

  def perform(participant_event_id)
    participant_event = ParticipantEvent.includes(:event, :participant).find_by(id: participant_event_id)
    return unless participant_event&.complete?

    channel_id = participant_event.event.slack_channel_id
    slack_id = participant_event.participant.slack_user_id
    return if channel_id.blank? || slack_id.blank?

    SlackService.new.invite_to_channel(channel_id: channel_id, user_id: slack_id)
  rescue SlackService::RateLimited
    raise
  rescue SlackService::Error => e
    # Not retried: the usual causes (bot not in the channel, user outside the
    # workspace) need a person to fix, and "Sync Slack channel" catches them up.
    Rails.logger.error("[InviteToEventSlackChannel] Failed to add #{slack_id} to #{channel_id}: #{e.message}")
  end
end
