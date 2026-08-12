class IncidentReportMailer < ApplicationMailer
  layout false

  EMAIL_ATTACHMENT_BUDGET = 8.megabytes

  def new_report(incident_report)
    @incident_report = incident_report
    @event_name = incident_report.event_name
    @skipped_attachments = []

    budget = EMAIL_ATTACHMENT_BUDGET
    incident_report.attachments.each do |attachment|
      if attachment.byte_size <= budget
        attachments[attachment.filename.to_s] = attachment.download
        budget -= attachment.byte_size
      else
        @skipped_attachments << attachment.filename.to_s
      end
    end

    mail(
      to: notify_email,
      reply_to: incident_report.reporter_email,
      subject: "[#{incident_report.priority.humanize}] Incident Report – #{@event_name}"
    )
  end

  private

  def notify_email
    configured = Setting.incident_reports_notify_email_list
    return configured if configured.any?

    Rails.application.credentials.dig(:incident_reports, :notify_email) ||
      ENV["INCIDENT_REPORTS_NOTIFY_EMAIL"] ||
      "deven@hackclub.com"
  end
end
