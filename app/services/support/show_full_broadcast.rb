module Support
  # The broadcast WhatsApp template can only carry a short preview. Its "Show
  # it here" button sends a reply, which opens WhatsApp's 24-hour window, so we
  # can answer with the whole message as plain text.
  class ShowFullBroadcast
    def self.call(phone:, payload:)
      new(phone:, payload:).call
    end

    def initialize(phone:, payload:)
      @phone = phone
      @payload = payload
    end

    # Returns true when the message was a button tap on a broadcast we sent
    # this number, whether or not the reply could be sent.
    def call
      return false if @payload["ButtonText"].blank? && @payload["ButtonPayload"].blank?

      original_sid = @payload["OriginalRepliedMessageSid"]
      return false if original_sid.blank?

      log = AutomatedSmsLog.whatsapp.for_phone(@phone).find_by(twilio_sid: original_sid)
      delivery = log&.message_delivery
      return false unless delivery

      TwilioService.new.send_whatsapp_text(to: @phone, body: full_text(delivery), source: "Broadcast message")
      true
    rescue TwilioService::Error => e
      Rails.logger.error("[Support::ShowFullBroadcast] #{e.message}")
      true
    end

    private

    def full_text(delivery)
      message = delivery.message
      link = "View on Attend: #{message_url(delivery)}"
      heading = "*#{message.event.name}*"
      room = TwilioService::MAX_BODY_LENGTH - heading.length - link.length - 4

      [ heading, message.body_as_plain.to_s.strip.truncate(room), link ].join("\n\n")
    end

    def message_url(delivery)
      Rails.application.routes.url_helpers.dashboard_message_url(
        delivery,
        host: Rails.application.credentials.dig(:app, :host) || ENV.fetch("APP_HOST", "attend.hackclub.com"),
        protocol: "https"
      )
    end
  end
end
