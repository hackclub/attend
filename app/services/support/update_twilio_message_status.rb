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

      begin
        suppress_dead_number(message_sid:, status:, error_code:)
      rescue => e
        Rails.logger.error("[Support::UpdateTwilioMessageStatus] suppression failed: #{e.class}: #{e.message}")
      end

      message = TicketMessage.find_by(twilio_message_sid: message_sid)
      return unless message

      attributes = { twilio_status: status }
      attributes[:error_message] = "#{error_code}: #{error_message}" if error_code.present?

      message.update!(attributes)
    end

    private

    # An automated text that failed for good (see SmsSuppression) keeps that
    # number off SMS for a while, so later broadcasts don't hit it again.
    def suppress_dead_number(message_sid:, status:, error_code:)
      return unless WhatsappSmsFallback::FAILED_STATUSES.include?(status) && SmsSuppression.permanent?(error_code)

      log = AutomatedSmsLog.sms.find_by(twilio_sid: message_sid)
      SmsSuppression.record(phone: log.phone_number, error_code:) if log
    end
  end
end
