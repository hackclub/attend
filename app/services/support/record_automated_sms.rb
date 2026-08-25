module Support
  # Records an automated (system-sent) SMS so support agents can see it in
  # ticket chat history. Called by TwilioService after a successful send.
  #
  # If the recipient already has an open SMS ticket, the message is appended
  # to that thread immediately. Otherwise the log is picked up later by
  # ProcessIncomingTwilioMessage when a reply opens a new ticket.
  class RecordAutomatedSms
    def self.call(phone:, body:, twilio_sid: nil, source: nil)
      new(phone:, body:, twilio_sid:, source:).call
    end

    def initialize(phone:, body:, twilio_sid: nil, source: nil)
      @phone = phone
      @body = body
      @twilio_sid = twilio_sid
      @source = source
    end

    def call
      normalized = PhoneNormalizer.normalize(@phone)
      return if normalized.blank? || @body.blank?

      log = AutomatedSmsLog.create!(
        phone_number: normalized,
        body: @body,
        twilio_sid: @twilio_sid,
        source: @source,
        sent_at: Time.current
      )

      materialize_into_open_ticket(log)

      log
    end

    private

    def materialize_into_open_ticket(log)
      ticket = Ticket.where(phone_number: log.phone_number, channel: "sms", status: "open")
                     .order(created_at: :desc)
                     .first
      return unless ticket

      TicketMessage.create!(
        ticket: ticket,
        direction: "outbound",
        channel: "sms",
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
