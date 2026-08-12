class InitiateEmergencyIncidentCallsJob < ApplicationJob
  queue_as :default

  def perform(incident_report_id)
    report = IncidentReport.find(incident_report_id)
    return unless report.emergency?
    return unless Setting.twilio_enabled?

    phones = Setting.incident_reports_emergency_phone_list
    return if phones.empty?

    from = Setting.twilio_from_number.presence || ENV["TWILIO_FROM_NUMBER"]
    sid = Rails.application.credentials.dig(:twilio, :account_sid) || ENV["TWILIO_ACCOUNT_SID"]
    token = Rails.application.credentials.dig(:twilio, :auth_token) || ENV["TWILIO_AUTH_TOKEN"]

    unless from.present? && sid.present? && token.present?
      Rails.logger.warn("[EmergencyCall] Twilio not configured; skipping calls for report #{report.id}")
      return
    end

    client = Twilio::REST::Client.new(sid, token)

    phones.each do |entry|
      client.calls.create(to: entry[:phone], from: from, url: voice_url(report, entry[:name]))
    rescue Twilio::REST::RestError => e
      Rails.logger.error("[EmergencyCall] Call to #{entry[:phone]} failed: #{e.message}")
    end
  end

  private

  def voice_url(report, name)
    opts =
      if ENV["TWILIO_PUBLIC_HOST"].present?
        { host: ENV["TWILIO_PUBLIC_HOST"], protocol: "https" }
      else
        Rails.application.config.action_mailer.default_url_options.presence ||
          { host: "attend.hackclub.com", protocol: "https" }
      end
    Rails.application.routes.url_helpers.twilio_incident_voice_url(report, name: name.presence, **opts)
  end
end
