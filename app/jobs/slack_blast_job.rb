class SlackBlastJob < ApplicationJob
  queue_as :default

  def perform(slack_blast_id:)
    slack_blast = SlackBlast.find(slack_blast_id)
    slack_service = SlackService.new

    slack_blast.update!(status: :in_progress)

    slack_blast.slack_blast_recipients.pending.find_each do |recipient|
      begin
        participant = recipient.participant_event.participant
        message_with_footer = build_message_with_footer(slack_blast, recipient.participant_event)
        result = slack_service.send_dm(
          user_id: participant.slack_user_id,
          text: message_with_footer
        )
        recipient.update!(status: :sent, slack_message_ts: result[:ts])
      rescue SlackService::Error => e
        recipient.update!(status: :failed, error_message: e.message)
        Rails.logger.error("[SlackBlast] Failed to send to #{participant.slack_user_id}: #{e.message}")
      end

      sleep 0.5
    end

    slack_blast.update_counts!
    slack_blast.update!(status: :completed)

    Rails.logger.info("[SlackBlast] Completed: #{slack_blast.sent_count} sent, #{slack_blast.failed_count} failed")
  end

  private

  def build_message_with_footer(slack_blast, participant_event)
    event = slack_blast.event
    dashboard_url = "https://attend.hackclub.com/dashboard/events/#{participant_event.id}"
    footer = "_You're receiving this message because you're a confirmed attendee at <#{dashboard_url}|#{event.name}>._"

    "#{slack_blast.message_as_slack}\n\n#{footer}"
  end
end
