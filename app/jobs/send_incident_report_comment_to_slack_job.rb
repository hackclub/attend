class SendIncidentReportCommentToSlackJob < ApplicationJob
  queue_as :default

  def perform(comment_id)
    comment = IncidentReportComment.find(comment_id)
    report = comment.incident_report

    return unless report.slack_message_ts.present? && report.slack_channel_id.present?

    SlackService.new.send_to_channel(
      channel_id: report.slack_channel_id,
      text: build_comment_text(comment),
      thread_ts: report.slack_message_ts
    )
  end

  private

  def build_comment_text(comment)
    user = comment.user
    slack_id = user&.oidc_claims&.dig("slack_id") || user&.participant&.slack_user_id
    mention = slack_id.present? ? "<@#{slack_id}>" : (user&.display_name_or_fallback || "Someone")

    status_text = comment.new_status.present? ? " and changed status to *#{comment.new_status.humanize.titleize}*" : ""

    text = "💬 #{mention} commented#{status_text}:\n\n#{comment.body}"

    if comment.attachments.attached?
      files = comment.attachments.map { |a| "• #{a.filename}" }.join("\n")
      text += "\n\n📎 *#{comment.attachments.count} #{"attachment".pluralize(comment.attachments.count)}:*\n#{files}"
    end

    text
  end
end
