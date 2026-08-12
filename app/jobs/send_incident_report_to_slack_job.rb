class SendIncidentReportToSlackJob < ApplicationJob
  queue_as :default

  STATUS_EMOJI = { "open" => "🟦", "in_review" => "🟨", "resolved" => "🟩" }.freeze

  def self.channel_id
    Setting.incident_reports_slack_channel_id ||
      Rails.application.credentials.dig(:incident_reports, :slack_channel_id) ||
      (Rails.env.production? ? "G01DBHPLK25" : "C0834H301MF")
  end

  def perform(incident_report_id)
    report = IncidentReport.find(incident_report_id)

    text = "Incident report (#{report.priority.humanize}, #{report.status.humanize}) for #{report.event_name}"
    blocks = build_blocks(report)
    service = SlackService.new

    if report.slack_message_ts.present? && report.slack_channel_id.present?
      service.update_channel_message(
        channel_id: report.slack_channel_id,
        ts: report.slack_message_ts,
        text: text,
        blocks: blocks
      )
    else
      channel_id = self.class.channel_id
      result = service.send_to_channel(channel_id: channel_id, text: text, blocks: blocks)

      if result[:success] && result[:ts].present?
        report.update_columns(slack_message_ts: result[:ts], slack_channel_id: channel_id)
      end

      send_dms(service, report, text, blocks)
    end
  end

  private

  def send_dms(service, report, text, blocks)
    Setting.incident_reports_slack_dm_user_id_list.each do |user_id|
      service.send_dm_with_blocks(user_id: user_id, text: text, blocks: blocks)
    rescue SlackService::Error => e
      Rails.logger.error("[IncidentReportSlack] DM to #{user_id} failed: #{e.message}")
    end
  end

  def build_blocks(report)
    priority_emoji = { "emergency" => "🚨", "elevated" => "⚠️", "standard" => "📝" }[report.priority] || "📝"

    [
      {
        type: "header",
        text: { type: "plain_text", text: "#{priority_emoji} Incident Report", emoji: true }
      },
      {
        type: "section",
        fields: [
          { type: "mrkdwn", text: "*Priority:*\n#{report.priority_label}" },
          { type: "mrkdwn", text: "*Status:*\n#{STATUS_EMOJI[report.status]} #{report.status.humanize}" },
          { type: "mrkdwn", text: "*Type:*\n#{report.incident_type_label}" },
          { type: "mrkdwn", text: "*Event:*\n#{report.event_name}" },
          { type: "mrkdwn", text: "*Reporter:*\n#{report.reporter_name} (#{report.role_label})" }
        ]
      },
      {
        type: "section",
        fields: [
          { type: "mrkdwn", text: "*Email:*\n<mailto:#{report.reporter_email}|#{report.reporter_email}>" },
          { type: "mrkdwn", text: "*Phone:*\n#{report.reporter_phone}" }
        ]
      },
      *(report.medical_emergency? ? [ {
        type: "section",
        text: { type: "mrkdwn", text: "*Emergency services called?* #{report.emergency_services_called? ? 'Yes' : 'No'}" }
      } ] : []),
      {
        type: "section",
        text: { type: "mrkdwn", text: "*Summary:*\n#{report.summary}" }
      },
      {
        type: "actions",
        elements: [
          {
            type: "button",
            text: { type: "plain_text", text: "View on Attend", emoji: true },
            url: incident_url(report),
            style: "primary"
          }
        ]
      },
      {
        type: "context",
        elements: [
          { type: "mrkdwn", text: "Full details and any attachments were emailed to HQ. This report is confidential." }
        ]
      }
    ]
  end

  def incident_url(report)
    opts = Rails.application.config.action_mailer.default_url_options.presence ||
      { host: "attend.hackclub.com", protocol: "https" }
    Rails.application.routes.url_helpers.admin_incident_url(report, **opts)
  end
end
