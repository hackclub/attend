module Support
  class ProcessIncomingSignalMessage
    def self.call(payload)
      new(payload).call
    end

    def initialize(payload)
      @payload = payload
    end

    def call
      from_raw = @payload["from"]
      to_raw = @payload["to"]
      body = @payload["body"].to_s
      message_sid = @payload["messageSid"]

      phone = PhoneNormalizer.normalize(from_raw)
      return unless phone.present? && body.present?

      ticket = find_or_create_ticket(phone: phone, signal_to: to_raw)
      new_chat = ticket.previously_new_record?

      message = TicketMessage.create!(
        ticket: ticket,
        direction: "inbound",
        channel: "signal",
        body: body,
        signal_message_sid: message_sid,
        raw_payload: @payload,
        sent_at: Time.current
      )

      ticket.update_columns(
        last_inbound_at: Time.current,
        last_message_at: Time.current
      )

      attach_subject_if_unset(ticket, phone)

      if new_chat
        SupportTicketMailer.new_chat(ticket_id: ticket.id, message_id: message.id).deliver_later
        SendSupportTicketSmsNotificationJob.perform_later(message.id, "new_ticket")
      end

      ticket
    end

    private

    def find_or_create_ticket(phone:, signal_to:)
      scope = Ticket.unmerged.where(
        phone_number: phone,
        channel: "signal",
        status: "open"
      )

      existing = scope.order(created_at: :desc).first
      return existing if existing

      Ticket.create!(
        phone_number: phone,
        channel: "signal",
        status: "open",
        twilio_to_number: signal_to,
        last_inbound_at: Time.current,
        last_message_at: Time.current
      )
    end

    def attach_subject_if_unset(ticket, phone)
      return if ticket.subject_type.present?

      participant = Participant.find_by(phone: phone)
      guardian = Guardian.find_by(phone: phone)

      subject = participant || guardian
      return unless subject

      ticket.update_columns(
        subject_type: subject.class.name,
        subject_id: subject.id
      )
    end
  end
end
