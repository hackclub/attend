module Support
  class UpdateTwilioMessageStatus
    def self.call(payload)
      new(payload).call
    end

    def initialize(payload)
      @payload = payload
    end

    def call
      message_sid = @payload["MessageSid"]
      status = @payload["MessageStatus"]
      error_code = @payload["ErrorCode"]
      error_message = @payload["ErrorMessage"]

      return unless message_sid.present?

      begin
        WhatsappSmsFallback.call(message_sid:, status:, error_code:)
      rescue => e
        Rails.logger.error("[Support::UpdateTwilioMessageStatus] fallback failed: #{e.class}: #{e.message}")
      end

      message = TicketMessage.find_by(twilio_message_sid: message_sid)
      return unless message

      attributes = { twilio_status: status }
      attributes[:error_message] = "#{error_code}: #{error_message}" if error_code.present?

      message.update!(attributes)
    end
  end
end
