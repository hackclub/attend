class SendIncidentReportUpdateSmsJob < ApplicationJob
  queue_as :default

  def perform(comment_id)
    comment = IncidentReportComment.find(comment_id)
    report = comment.incident_report
    return if report.reporter_phone.blank?

    sender = comment.user&.display_name_or_fallback
    body = sender.present? ? "#{sender}: #{comment.body}" : comment.body

    TwilioService.new.send_sms(to: report.reporter_phone, body: body, source: "Incident reports")
  rescue TwilioService::Error => e
    Rails.logger.error("[IncidentReportSms] update SMS failed for comment #{comment_id}: #{e.message}")
  end
end
