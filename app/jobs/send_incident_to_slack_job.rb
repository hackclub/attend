class SendIncidentToSlackJob < ApplicationJob
  queue_as :default

  CONDUCT_CHANNEL_ID = Rails.env.production? ? "G01DBHPLK25" : "C0834H301MF"

  def perform(incident_id, sent_by_user_id)
    incident = Incident.find(incident_id)
    sent_by = User.find(sent_by_user_id)

    blocks = build_slack_blocks(incident, sent_by)
    text = "Conduct Report: #{incident.summary.presence || 'No summary'}"

    result = SlackService.new.send_to_channel(
      channel_id: CONDUCT_CHANNEL_ID,
      text: text,
      blocks: blocks
    )

    incident.update!(slack_message_ts: result[:ts]) if result[:success] && result[:ts].present?
  end

  private

  def build_slack_blocks(incident, sent_by)
    participant_lines = incident.incident_participants.includes(participant_event: :participant).map do |ip|
      participant = ip.participant_event.participant
      participant_event = ip.participant_event
      slack_id = participant_event.slack_user_id.presence || participant.slack_user_id
      name = participant.preferred_name.presence || participant.legal_first_name
      email = participant.email

      if slack_id.present?
        "<@#{slack_id}> ✉️ <mailto:#{email}|#{email}>"
      else
        "#{name} ✉️ <mailto:#{email}|#{email}>"
      end
    end

    staff_lines = incident.helping_staff.map do |staff|
      format_user_mention(staff)
    end

    [
      {
        type: "header",
        text: {
          type: "plain_text",
          text: "🚨 Conduct Report",
          emoji: true
        }
      },
      {
        type: "section",
        fields: [
          {
            type: "mrkdwn",
            text: "*Event:*\n#{incident.event.name}"
          },
          {
            type: "mrkdwn",
            text: "*Severity:*\n#{incident.severity.humanize}"
          },
          {
            type: "mrkdwn",
            text: "*Status:*\n#{incident.status.humanize}"
          },
          {
            type: "mrkdwn",
            text: "*Occurred:*\n#{incident.occurred_at&.strftime('%B %d, %Y at %H:%M') || 'Not specified'}"
          }
        ]
      },
      {
        type: "section",
        fields: [
          {
            type: "mrkdwn",
            text: "*Participants Involved:*\n#{participant_lines.any? ? participant_lines.join("\n") : 'None specified'}"
          },
          {
            type: "mrkdwn",
            text: "*Location:*\n#{incident.location.presence || 'Not specified'}"
          }
        ]
      },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: "*Staff Who Helped:*\n#{staff_lines.any? ? staff_lines.join(", ") : 'None recorded'}"
        }
      },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: "*Summary:*\n#{incident.summary.presence || 'No summary provided'}"
        }
      },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: "*Details:*\n#{truncate_text(incident.details.presence || 'No details provided', 2900)}"
        }
      },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: "*Actions Taken:*\n#{truncate_text(incident.actions_taken.presence || 'No actions recorded yet', 2900)}"
        }
      },
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: "Sent to Slack by #{format_user_mention(sent_by)} • Reported by #{format_user_mention(incident.reported_by)}"
          }
        ]
      }
    ]
  end

  def format_user_mention(user)
    slack_id = user.oidc_claims&.dig("slack_id") || user.participant&.slack_user_id
    if slack_id.present?
      "<@#{slack_id}>"
    else
      user.display_name_or_fallback
    end
  end

  def truncate_text(text, max_length)
    return text if text.length <= max_length

    "#{text[0, max_length - 3]}..."
  end
end
