module Support
  class SendTicketMessage
    class DeliveryError < StandardError; end

    WHATSAPP_FROM_NUMBER = "+18556254225".freeze

    def self.call(ticket:, body:, user:)
      new(ticket:, body:, user:).call
    end

    def initialize(ticket:, body:, user:)
      @ticket = ticket
      @body = body
      @user = user
    end

    def call
      if @ticket.merged?
        raise DeliveryError, "This ticket was merged into ##{@ticket.merged_into_id.first(8)} — reply there instead."
      end

      if @ticket.signal?
        send_via_signal
      else
        send_via_twilio
      end
    end

    private

    def send_via_signal
      service = SignalService.new
      client_message_id = SecureRandom.uuid

      signal_response = service.send_message(
        to: @ticket.phone_number,
        body: @body,
        client_message_id: client_message_id
      )

      message = TicketMessage.create!(
        ticket: @ticket,
        direction: "outbound",
        channel: "signal",
        body: @body,
        user: @user,
        signal_message_sid: signal_response["messageSid"],
        sent_at: Time.current
      )

      @ticket.update_columns(
        last_outbound_at: Time.current,
        last_message_at: Time.current
      )

      assign_ticket_if_unassigned

      message
    rescue SignalService::Error => e
      raise DeliveryError, e.message
    rescue Faraday::ServerError => e
      raise DeliveryError, "Signal API server error: #{e.message}"
    rescue Faraday::TimeoutError => e
      raise DeliveryError, "Signal API timeout: #{e.message}"
    end

    def send_via_twilio
      if @ticket.freeform_reply_blocked?
        raise DeliveryError,
              "WhatsApp only accepts freeform replies for 24 hours after the contact's last message, " \
              "and that window has closed. Ask them to message us again, or reach them by SMS or email."
      end

      client = Twilio::REST::Client.new(
        Rails.application.credentials.dig(:twilio, :account_sid) || ENV.fetch("TWILIO_ACCOUNT_SID"),
        Rails.application.credentials.dig(:twilio, :auth_token) || ENV.fetch("TWILIO_AUTH_TOKEN")
      )

      to = case @ticket.channel
      when "whatsapp" then "whatsapp:#{@ticket.phone_number}"
      else @ticket.phone_number
      end

      from = if @ticket.whatsapp?
               "whatsapp:#{WHATSAPP_FROM_NUMBER}"
      else
               @ticket.twilio_to_number || sms_from_number
      end

      message_params = {
        from: from,
        to: to,
        body: @body
      }
      message_params[:status_callback] = status_callback_url if status_callback_url.present?

      twilio_msg = client.messages.create(**message_params)

      message = TicketMessage.create!(
        ticket: @ticket,
        direction: "outbound",
        channel: @ticket.channel,
        body: @body,
        user: @user,
        twilio_message_sid: twilio_msg.sid,
        twilio_status: twilio_msg.status,
        sent_at: Time.current
      )

      @ticket.update_columns(
        last_outbound_at: Time.current,
        last_message_at: Time.current
      )

      assign_ticket_if_unassigned

      message
    rescue Twilio::REST::RestError => e
      raise DeliveryError, e.message
    end

    def sms_from_number
      Setting.twilio_from_number.presence ||
        Rails.application.credentials.dig(:twilio, :from_number) ||
        ENV.fetch("TWILIO_FROM_NUMBER", nil)
    end

    def status_callback_url
      Rails.application.routes.url_helpers.twilio_status_url(
        host: default_url_host,
        protocol: "https"
      )
    end

    def default_url_host
      Rails.application.credentials.dig(:app, :host) ||
        ENV.fetch("APP_HOST", "attend.hackclub.com")
    end

    def assign_ticket_if_unassigned
      return if @ticket.assigned_to.present?
      return if @user.blank?

      @ticket.update!(assigned_to: @user)
    end
  end
end
