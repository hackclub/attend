class SyncSlackChannelJob < ApplicationJob
  queue_as :default

  # Slack conversations.invite is Tier 3 (~50 req/min) — pause between calls
  # so large events don't trip the rate limit.
  INVITE_PAUSE = 0.1

  def perform(event_id, send_emails: false)
    event = Event.find(event_id)
    return unless event.slack_channel_id.present?

    slack_service = SlackService.new
    completed_participants = event.participant_events.complete
    participants_with_slack = completed_participants
      .joins(:participant)
      .where.not(participants: { slack_user_id: [ nil, "" ] })
    participants_without_slack = completed_participants
      .joins(:participant)
      .where(participants: { slack_user_id: [ nil, "" ] })

    total = participants_with_slack.count
    added_count = 0
    already_member_count = 0
    failed_count = 0
    processed = 0

    participants_with_slack.includes(:participant).find_each do |pe|
      begin
        result = slack_service.invite_to_channel(
          channel_id: event.slack_channel_id,
          user_id: pe.participant.slack_user_id
        )
        result[:already_member] ? already_member_count += 1 : added_count += 1
      rescue SlackService::Error => e
        Rails.logger.error("[SyncSlackChannel] Failed to add #{pe.participant.slack_user_id}: #{e.message}")
        failed_count += 1
      end

      processed += 1
      if (processed % 10).zero? || processed == total
        broadcast(event, status: "running", total: total, processed: processed,
                  added: added_count, already_member: already_member_count, failed: failed_count)
      end
      sleep INVITE_PAUSE unless processed == total
    end

    emailed_count = 0
    if send_emails
      participants_without_slack.find_each do |pe|
        ParticipantMailer.slack_link_reminder(participant_event: pe).deliver_later
        emailed_count += 1
      end
    end

    event.update!(last_slack_sync_at: Time.current)

    broadcast(event, status: "completed", total: total, processed: processed,
              added: added_count, already_member: already_member_count,
              failed: failed_count, emailed: emailed_count)
  end

  private

  def broadcast(event, payload)
    ActionCable.server.broadcast("slack_sync_#{event.id}", payload)
  rescue => e
    Rails.logger.error("[SyncSlackChannelJob] Failed to broadcast: #{e.message}")
  end
end
