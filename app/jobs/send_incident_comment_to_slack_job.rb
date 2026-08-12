class SendIncidentCommentToSlackJob < ApplicationJob
  queue_as :default

  CONDUCT_CHANNEL_ID = Rails.env.production? ? "G01DBHPLK25" : "C0834H301MF"

  def perform(incident_comment_id)
    comment = IncidentComment.find(incident_comment_id)
    incident = comment.incident

    return unless incident.slack_message_ts.present?

    text = build_comment_text(comment)

    SlackService.new.send_to_channel(
      channel_id: CONDUCT_CHANNEL_ID,
      text: text,
      thread_ts: incident.slack_message_ts
    )
  end

  private

  def build_comment_text(comment)
    user = comment.user
    slack_id = user.oidc_claims&.dig("slack_id") || user.participant&.slack_user_id
    user_mention = slack_id.present? ? "<@#{slack_id}>" : user.display_name_or_fallback

    status_text = comment.new_status.present? ? " and changed status to *#{comment.new_status.humanize.titleize}*" : ""

    "💬 #{user_mention} commented#{status_text}:\n\n#{comment.body}"
  end
end
