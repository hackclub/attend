class TwilioService
  class Error < StandardError; end

  def initialize(account_sid: nil, auth_token: nil, from_number: nil)
    @account_sid = account_sid || ENV["TWILIO_ACCOUNT_SID"] || Rails.application.credentials.dig(:twilio, :account_sid)
    @auth_token = auth_token || ENV["TWILIO_AUTH_TOKEN"] || Rails.application.credentials.dig(:twilio, :auth_token)
    @from_number = from_number || Setting.twilio_from_number.presence || ENV["TWILIO_FROM_NUMBER"]
  end

  # log_body: alternative body to record in support chat history (e.g. with
  # sensitive codes redacted). source: short label for where the automated
  # message came from, shown to support agents.
  def send_sms(to:, body:, log_body: nil, source: nil)
    return { skipped: true, reason: "Twilio disabled" } unless Setting.twilio_enabled?
    raise Error, "Twilio not configured" unless configured?

    response = connection.post("Accounts/#{@account_sid}/Messages.json") do |req|
      req.body = URI.encode_www_form(
        To: to,
        From: @from_number,
        Body: body
      )
    end

    unless response.success?
      parsed = JSON.parse(response.body) rescue {}
      error_message = parsed.dig("message") || "SMS send failed with status #{response.status}"
      raise Error, error_message
    end

    parsed = JSON.parse(response.body)
    record_automated_sms(to: to, body: log_body || body, sid: parsed["sid"], source: source)
    { sid: parsed["sid"], status: parsed["status"] }
  rescue Faraday::Error => e
    raise Error, "Twilio API error: #{e.message}"
  end

  def configured?
    @account_sid.present? && @auth_token.present? && @from_number.present?
  end

  private

  # Never let history logging fail the send — the SMS has already gone out,
  # and raising here would make callers retry and double-send.
  def record_automated_sms(to:, body:, sid:, source:)
    Support::RecordAutomatedSms.call(phone: to, body: body, twilio_sid: sid, source: source)
  rescue => e
    Rails.logger.error("[TwilioService] Failed to record automated SMS: #{e.class}: #{e.message}")
    nil
  end

  def connection
    @connection ||= Faraday.new(url: "https://api.twilio.com/2010-04-01/") do |conn|
      conn.request :authorization, :basic, @account_sid, @auth_token
      conn.headers["Content-Type"] = "application/x-www-form-urlencoded"
    end
  end
end
