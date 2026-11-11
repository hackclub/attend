# Sends and checks one-time codes through Twilio Verify, which generates the
# code, expires it, and limits wrong guesses on Twilio's side, so we never
# hold the code ourselves.
class TwilioVerifyService
  class Error < StandardError; end

  CHANNELS = %w[sms whatsapp].freeze

  # Twilio answers a check against a verification that expired, was already
  # approved, or never existed with a 404 (error 20404). For us that's a wrong code.
  NOT_FOUND = 20404

  def self.available?
    Setting.twilio_enabled? && new.configured?
  end

  # WhatsApp is only used for numbers outside the +1 zone, and only once an
  # admin has attached a WhatsApp sender to the Verify service and switched it on.
  def self.default_channel_for(phone)
    Setting.twilio_verify_whatsapp? && !phone.to_s.start_with?("+1") ? "whatsapp" : "sms"
  end

  def initialize(service_sid: nil, account_sid: nil, auth_token: nil)
    @service_sid = service_sid || Setting.twilio_verify_service_sid
    @account_sid = account_sid || ENV["TWILIO_ACCOUNT_SID"] || Rails.application.credentials.dig(:twilio, :account_sid)
    @auth_token = auth_token || ENV["TWILIO_AUTH_TOKEN"] || Rails.application.credentials.dig(:twilio, :auth_token)
  end

  def configured?
    @service_sid.present? && @account_sid.present? && @auth_token.present?
  end

  # Returns the channel the code actually went out on. A WhatsApp send that
  # Twilio rejects up front (no sender, unsupported country) is retried as SMS
  # so the person still gets a code.
  def start(to:, channel: "sms")
    raise Error, "Twilio Verify not configured" unless configured?
    raise ArgumentError, "unknown channel #{channel.inspect}" unless CHANNELS.include?(channel)

    verifications.create(to: to, channel: channel)
    channel
  rescue Twilio::REST::RestError => e
    if channel == "whatsapp"
      Rails.logger.warn("[TwilioVerify] WhatsApp send rejected (#{e.code}), falling back to SMS")
      start(to: to, channel: "sms")
    else
      raise Error, "Twilio Verify error #{e.code}: #{e.error_message}"
    end
  end

  def check(to:, code:)
    raise Error, "Twilio Verify not configured" unless configured?

    service.verification_checks.create(to: to, code: code).status == "approved"
  rescue Twilio::REST::RestError => e
    return false if e.code == NOT_FOUND

    raise Error, "Twilio Verify error #{e.code}: #{e.error_message}"
  end

  private

  def verifications
    service.verifications
  end

  def service
    @service ||= Twilio::REST::Client.new(@account_sid, @auth_token).verify.v2.services(@service_sid)
  end
end
