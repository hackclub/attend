class TwilioService
  class Error < StandardError
    # Twilio's numeric error code, when the API returned one.
    attr_reader :code

    def initialize(message = nil, code: nil)
      super(message)
      @code = code&.to_s
    end
  end

  # Twilio rejects message bodies longer than this.
  MAX_BODY_LENGTH = 1600

  OPTED_OUT = { skipped: true, reason: "They opted out of texts" }.freeze

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
  #
  # The sender depends on the destination country (see SmsRoute), and some
  # numbers aren't texted at all: countries we can't reach, and numbers whose
  # last text failed for good (see SmsSuppression), and people who opted out
  # (see SmsOptOut). These come back as `skipped` rather than raising, since
  # there's nothing to retry.
  #
  # Every text ends with how to opt out: "Reply STOP" from the long code, or a
  # link from the "Hack Club" sender, which can't take replies.
  def send_sms(to:, body:, log_body: nil, source: nil)
    return { skipped: true, reason: "Twilio disabled" } unless Setting.twilio_enabled?
    raise Error, "Twilio not configured" unless configured?
    return OPTED_OUT if SmsOptOut.opted_out?(to)

    from = SmsRoute.sender_for(to, long_code: @from_number)
    return { skipped: true, reason: "We don't send texts to this country" } unless from
    return { skipped: true, reason: "Texts to this number recently failed for good" } if SmsSuppression.active?(to)

    footer = opt_out_footer(to, from)
    body = "#{body}\n\n#{footer}"
    log_body &&= "#{log_body}\n\n#{footer}"

    begin
      parsed = create_message(To: to, From: from, Body: body, StatusCallback: status_callback_url)
    rescue Error => e
      SmsSuppression.record(phone: to, error_code: e.code)
      raise
    end

    record_automated_message(to:, body: log_body || body, sid: parsed["sid"], source:, channel: "sms")
    { sid: parsed["sid"], status: parsed["status"], channel: "sms" }
  end

  def send_whatsapp_template(to:, content_sid:, variables: {}, sms_body: nil, log_body: nil, source: nil, message_delivery: nil)
    return { skipped: true, reason: "Twilio disabled" } unless Setting.twilio_enabled?
    raise Error, "Twilio not configured" unless configured?
    return OPTED_OUT if SmsOptOut.opted_out?(to)

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
      raise Error.new(error_message, code: parsed["code"])
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
    Rails.application.routes.url_helpers.twilio_status_url(host: public_host, protocol: "https")
  end

  def opt_out_footer(to, from)
    return "Reply STOP to opt out" if from == @from_number

    url = Rails.application.routes.url_helpers.sms_opt_out_url(SmsOptOut.token_for(to), host: public_host, protocol: "https")
    "Stop texts: #{url}"
  end

  def public_host
    Rails.application.credentials.dig(:app, :host) || ENV.fetch("APP_HOST", "attend.hackclub.com")
  end

  def connection
    @connection ||= Faraday.new(url: "https://api.twilio.com/2010-04-01/") do |conn|
      conn.request :authorization, :basic, @account_sid, @auth_token
      conn.headers["Content-Type"] = "application/x-www-form-urlencoded"
    end
  end
end
