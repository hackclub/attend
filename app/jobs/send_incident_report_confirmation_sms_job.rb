class SendIncidentReportConfirmationSmsJob < ApplicationJob
  queue_as :default

  MESSAGE = "Your report has been successfully submitted, and if we have any questions, " \
            "we'll follow up by calling you. Please make sure your phone is not on silent. " \
            "While you cannot reply to this message, we may post status updates. Should you " \
            "want to add an update, please call +1 855 625 4225.".freeze

  def perform(incident_report_id)
    report = IncidentReport.find(incident_report_id)
    return if report.reporter_phone.blank?

    TwilioService.new.send_sms(to: report.reporter_phone, body: MESSAGE)
  rescue TwilioService::Error => e
    Rails.logger.error("[IncidentReportSms] confirmation SMS failed for #{incident_report_id}: #{e.message}")
  end
end
