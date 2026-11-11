class TwilioService
  class Error < StandardError; end

  # Twilio rejects message bodies longer than this.
  MAX_BODY_LENGTH = 1600

  def initialize(account_sid: nil, auth_token: nil, from_number: nil)
    @account_sid = account_sid || ENV["TWILIO_ACCOUNT_SID"] || Rails.application.credentials.dig(:twilio, :account_sid)
    @auth_token = auth_token || ENV["TWILIO_AUTH_TOKEN"] || Rails.application.credentials.dig(:twilio, :auth_token)
    @from_number = from_number || Setting.twilio_from_number.presence || ENV["TWILIO_FROM_NUMBER"]
  end

  # WhatsApp goes to numbers outside the +1 zone once an admin switches it on,
  # unless an earlier send showed the number isn't on WhatsApp.
  def self.whatsapp_for?(phone)
    phone = phone.to_s
    Setting.whatsapp_enabled? &&
      phone.start_with?("+") && !phone.start_with?("+1") &&
      !AutomatedSmsLog.whatsapp_unavailable?(phone)
  end

  # Sends an automated message on whichever channel suits the number: a
  # pre-approved WhatsApp template, or `sms_body` as a plain text. If the
  # WhatsApp message fails later, WhatsappSmsFallback resends `sms_body`.
  def send_message(to:, sms_body:, whatsapp_template:, whatsapp_variables: {}, log_body: nil, source: nil, message_delivery: nil)
    if self.class.whatsapp_for?(to)
      send_whatsapp_template(to:, content_sid: whatsapp_template, variables: whatsapp_variables,
                             sms_body:, log_body:, source:, message_delivery:)
    else
      send_sms(to:, body: sms_body, log_body:, source:)
    end
  end

  # log_body: alternative body to record in support chat history (e.g. with
  # sensitive codes redacted). source: short label for where the automated
  # message came from, shown to support agents.
  def send_sms(to:, body:, log_body: nil, source: nil)
    return { skipped: true, reason: "Twilio disabled" } unless Setting.twilio_enabled?
    raise Error, "Twilio not configured" unless configured?

    parsed = create_message(To: to, From: @from_number, Body: body)
    record_automated_message(to:, body: log_body || body, sid: parsed["sid"], source:, channel: "sms")
    { sid: parsed["sid"], status: parsed["status"], channel: "sms" }
  end

  def send_whatsapp_template(to:, content_sid:, variables: {}, sms_body: nil, log_body: nil, source: nil, message_delivery: nil)
    return { skipped: true, reason: "Twilio disabled" } unless Setting.twilio_enabled?
    raise Error, "Twilio not configured" unless configured?

    params = {
      To: "whatsapp:#{to}",
      From: "whatsapp:#{@from_number}",
      ContentSid: content_sid,
      StatusCallback: status_callback_url
    }
    params[:ContentVariables] = variables.transform_keys(&:to_s).to_json if variables.present?

    parsed = create_message(**params)
    record_automated_message(
      to:, body: log_body || sms_body || "(WhatsApp template)", sid: parsed["sid"], source:,
      channel: "whatsapp", content_sid:, sms_fallback_body: sms_body, message_delivery:
    )
    { sid: parsed["sid"], status: parsed["status"], channel: "whatsapp" }
  end

  # Plain WhatsApp text. Meta only delivers these within 24 hours of the
  # person's last message to us, so only send one in reply to something.
  def send_whatsapp_text(to:, body:, source: nil)
    return { skipped: true, reason: "Twilio disabled" } unless Setting.twilio_enabled?
    raise Error, "Twilio not configured" unless configured?

    body = body.to_s.truncate(MAX_BODY_LENGTH)
    parsed = create_message(To: "whatsapp:#{to}", From: "whatsapp:#{@from_number}", Body: body,
                            StatusCallback: status_callback_url)
    record_automated_message(to:, body:, sid: parsed["sid"], source:, channel: "whatsapp")
    { sid: parsed["sid"], status: parsed["status"], channel: "whatsapp" }
  end

  def configured?
    @account_sid.present? && @auth_token.present? && @from_number.present?
  end

  private

  def create_message(**params)
    response = connection.post("Accounts/#{@account_sid}/Messages.json") do |req|
      req.body = URI.encode_www_form(params)
    end

    unless response.success?
      parsed = JSON.parse(response.body) rescue {}
      error_message = parsed.dig("message") || "Message send failed with status #{response.status}"
      raise Error, error_message
    end

    JSON.parse(response.body)
  rescue Faraday::Error => e
    raise Error, "Twilio API error: #{e.message}"
  end

  # Never let history logging fail the send — the message has already gone
  # out, and raising here would make callers retry and double-send.
  def record_automated_message(to:, body:, sid:, source:, **attributes)
    Support::RecordAutomatedSms.call(phone: to, body: body, twilio_sid: sid, source: source, **attributes)
  rescue => e
    Rails.logger.error("[TwilioService] Failed to record automated message: #{e.class}: #{e.message}")
    nil
  end

  def status_callback_url
    Rails.application.routes.url_helpers.twilio_status_url(
      host: Rails.application.credentials.dig(:app, :host) || ENV.fetch("APP_HOST", "attend.hackclub.com"),
      protocol: "https"
    )
  end

  def connection
    @connection ||= Faraday.new(url: "https://api.twilio.com/2010-04-01/") do |conn|
      conn.request :authorization, :basic, @account_sid, @auth_token
      conn.headers["Content-Type"] = "application/x-www-form-urlencoded"
    end
  end
end
