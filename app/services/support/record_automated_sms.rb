module Support
  # Records an automated (system-sent) SMS or WhatsApp message so support
  # agents can see it in ticket chat history. Called by TwilioService after a
  # successful send.
  #
  # If the recipient already has an open ticket on the same channel, the
  # message is appended to that thread immediately. Otherwise the log is
  # picked up later by ProcessIncomingTwilioMessage when a reply opens a new ticket.
  class RecordAutomatedSms
    def self.call(phone:, body:, twilio_sid: nil, source: nil, **attributes)
      new(phone:, body:, twilio_sid:, source:, **attributes).call
    end

    # attributes: channel, content_sid, sms_fallback_body, message_delivery
    def initialize(phone:, body:, twilio_sid: nil, source: nil, **attributes)
      @phone = phone
      @body = body
      @twilio_sid = twilio_sid
      @source = source
      @attributes = attributes
    end

    def call
      normalized = PhoneNormalizer.normalize(@phone)
      return if normalized.blank? || @body.blank?

      log = AutomatedSmsLog.create!(
        phone_number: normalized,
        body: @body,
        twilio_sid: @twilio_sid,
        source: @source,
        sent_at: Time.current,
        **@attributes
      )

      materialize_into_open_ticket(log)

      log
    end

    private

    def materialize_into_open_ticket(log)
      ticket = Ticket.where(phone_number: log.phone_number, channel: log.channel, status: "open")
                     .order(created_at: :desc)
                     .first
      return unless ticket

      TicketMessage.create!(
        ticket: ticket,
        direction: "outbound",
        channel: log.channel,
        automated: true,
        body: log.body,
        twilio_message_sid: log.twilio_sid,
        raw_payload: { "source" => log.source }.compact,
        sent_at: log.sent_at
      )

      ticket.update_columns(last_message_at: log.sent_at)
    end
  end
end
