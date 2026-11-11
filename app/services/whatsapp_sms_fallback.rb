# When a WhatsApp message we started fails (the number isn't on WhatsApp,
# Meta declined it, and so on), Twilio's status callback lands here and we
# resend the same message as SMS. Not-on-WhatsApp errors are stored on the
# log, which keeps that number on SMS for a while (see AutomatedSmsLog).
class WhatsappSmsFallback
  FAILED_STATUSES = %w[failed undelivered].freeze

  def self.call(message_sid:, status:, error_code:)
    new(message_sid:, status:, error_code:).call
  end

  def initialize(message_sid:, status:, error_code:)
    @message_sid = message_sid
    @status = status
    @error_code = error_code.presence
  end

  def call
    return unless FAILED_STATUSES.include?(@status) && @message_sid.present?

    log = AutomatedSmsLog.whatsapp.find_by(twilio_sid: @message_sid)
    return unless log&.sms_fallback_body.present?

    # Twilio can report "failed" and then "undelivered" for the same message;
    # claiming the row first means only one of them sends the SMS.
    claimed = AutomatedSmsLog.where(id: log.id, fell_back_at: nil)
                             .update_all(fell_back_at: Time.current, error_code: @error_code)
    return if claimed.zero?

    result = TwilioService.new.send_sms(to: log.phone_number, body: log.sms_fallback_body, source: log.source)
    log.message_delivery&.update!(external_id: result[:sid]) if result[:sid]
  rescue TwilioService::Error => e
    Rails.logger.error("[WhatsappSmsFallback] SMS fallback for #{@message_sid} failed: #{e.message}")
    log&.message_delivery&.update!(status: :failed, error_message: "WhatsApp failed (#{@error_code}), then SMS failed: #{e.message}")
  end
end
