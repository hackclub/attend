module Support
  class ProcessIncomingTwilioMessage
    TWILIO_MEDIA_HOSTS = %w[
      api.twilio.com
      mcs.us1.twilio.com
    ].freeze

    def self.call(payload)
      new(payload).call
    end

    def initialize(payload)
      @payload = payload
    end

    def call
      from_raw = @payload["From"]
      to_raw = @payload["To"]
      body = @payload["Body"].to_s
      message_sid = @payload["MessageSid"]
      channel = infer_channel(from_raw)

      phone = PhoneNormalizer.normalize(from_raw)
      num_media = @payload["NumMedia"].to_i

      # Tapping "Show it here" on a broadcast is answered automatically and
      # shouldn't open a support ticket.
      return if channel == "whatsapp" && phone.present? && Support::ShowFullBroadcast.call(phone:, payload: @payload)
      return unless phone.present? && (body.present? || num_media > 0)
      # STOP and START only change whether we text them; they aren't support
      # questions, so they don't open a ticket.
      return if handle_opt_out_keyword(phone:, channel:, body:)

      ticket = find_or_create_ticket(phone:, channel:, twilio_to: to_raw)
      new_chat = ticket.previously_new_record?

      backfill_automated_messages(ticket) if new_chat

      message = TicketMessage.create!(
        ticket: ticket,
        direction: "inbound",
        channel: channel,
        body: body.presence || "(media)",
        twilio_message_sid: message_sid,
        raw_payload: @payload,
        sent_at: Time.current
      )

      attach_media(message)

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

    # Twilio answers STOP and START on SMS itself (and blocks the number at
    # its end); WhatsApp has no such handling, so we confirm there.
    def handle_opt_out_keyword(phone:, channel:, body:)
      action = SmsOptOut.keyword_action(body, opt_out_type: @payload["OptOutType"])
      return false unless action
      # "Yes" is a start word, but from someone who never opted out it's just
      # an answer, and support should see it.
      return false if action == :start && !SmsOptOut.opted_out?(phone)

      if action == :stop
        SmsOptOut.opt_out!(phone, source: :keyword)
        confirm_on_whatsapp(phone, "You won't get any more automated messages from Hack Club events here. Reply START to turn them back on.") if channel == "whatsapp"
      else
        SmsOptOut.opt_in!(phone)
        confirm_on_whatsapp(phone, "You'll get automated messages from Hack Club events here again. Reply STOP to turn them off.") if channel == "whatsapp"
      end
      true
    end

    def confirm_on_whatsapp(phone, text)
      TwilioService.new.send_whatsapp_text(to: phone, body: text, source: "Opt-out")
    rescue TwilioService::Error => e
      Rails.logger.error("[Support::ProcessIncomingTwilioMessage] opt-out confirmation failed: #{e.message}")
    end

    def infer_channel(from_raw)
      from_raw.to_s.start_with?("whatsapp:") ? "whatsapp" : "sms"
    end

    def find_or_create_ticket(phone:, channel:, twilio_to:)
      twilio_to_normalized = twilio_to.to_s.sub(/\Awhatsapp:/, "")

      scope = Ticket.unmerged.where(
        phone_number: phone,
        channel: channel,
        status: "open"
      )

      existing = scope.order(created_at: :desc).first
      return existing if existing

      Ticket.create!(
        phone_number: phone,
        channel: channel,
        status: "open",
        twilio_to_number: twilio_to_normalized,
        last_inbound_at: Time.current,
        last_message_at: Time.current
      )
    end

    BACKFILL_WINDOW = 7.days
    BACKFILL_LIMIT = 10

    # When a reply opens a new ticket, pull in recent automated messages sent
    # to this number on the same channel, so the agent can see what the person
    # is responding to.
    def backfill_automated_messages(ticket)
      return unless ticket.sms? || ticket.whatsapp?

      logs = AutomatedSmsLog.for_phone(ticket.phone_number)
                            .where(channel: ticket.channel)
                            .where(sent_at: BACKFILL_WINDOW.ago..)
                            .order(sent_at: :desc)
                            .limit(BACKFILL_LIMIT)
                            .to_a
                            .reverse

      sids = logs.filter_map(&:twilio_sid)
      already_shown = TicketMessage.where(twilio_message_sid: sids).pluck(:twilio_message_sid).to_set

      logs.each do |log|
        next if log.twilio_sid.present? && already_shown.include?(log.twilio_sid)

        TicketMessage.create!(
          ticket: ticket,
          direction: "outbound",
          channel: ticket.channel,
          automated: true,
          body: log.body,
          twilio_message_sid: log.twilio_sid,
          raw_payload: { "source" => log.source }.compact,
          sent_at: log.sent_at
        )
      end
    rescue => e
      Rails.logger.error("[Support::ProcessIncomingTwilioMessage] Backfill failed for ticket #{ticket.id}: #{e.class}: #{e.message}")
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

    def attach_media(message)
      require "uri"

      num_media = @payload["NumMedia"].to_i
      Rails.logger.info("[Support::ProcessIncomingTwilioMessage] attach_media called, num_media=#{num_media}")
      return if num_media.zero?

      account_sid = ENV["TWILIO_ACCOUNT_SID"] || Rails.application.credentials.dig(:twilio, :account_sid)
      auth_token = ENV["TWILIO_AUTH_TOKEN"] || Rails.application.credentials.dig(:twilio, :auth_token)

      num_media.times do |i|
        media_url = @payload["MediaUrl#{i}"]
        content_type = @payload["MediaContentType#{i}"]
        Rails.logger.info("[Support::ProcessIncomingTwilioMessage] Processing media #{i}: url=#{media_url.present?}, content_type=#{content_type}")
        next unless media_url.present?

        unless valid_twilio_media_url?(media_url)
          Rails.logger.warn("[Support::ProcessIncomingTwilioMessage] Skipping invalid Twilio media URL for media #{i}")
          next
        end

        require "faraday/follow_redirects"
        conn = Faraday.new do |f|
          f.response :follow_redirects, callback: method(:validate_twilio_media_redirect!)
          f.adapter Faraday.default_adapter
        end

        response = conn.get(media_url) do |req|
          req.headers["Authorization"] = "Basic #{Base64.strict_encode64("#{account_sid}:#{auth_token}")}"
        end

        Rails.logger.info("[Support::ProcessIncomingTwilioMessage] Media fetch status=#{response.status}, body_size=#{response.body&.bytesize}")
        next unless response.success?

        extension = Rack::Mime::MIME_TYPES.invert[content_type] || ".bin"
        filename = "media_#{i}#{extension}"

        message.media.attach(
          io: StringIO.new(response.body),
          filename: filename,
          content_type: content_type
        )
        Rails.logger.info("[Support::ProcessIncomingTwilioMessage] Media attached: #{filename}")
      end
    rescue => e
      Rails.logger.error("[Support::ProcessIncomingTwilioMessage] Failed to attach media: #{e.class}: #{e.message}")
    end

    def valid_twilio_media_url?(url)
      uri = URI.parse(url.to_s)
      uri.is_a?(URI::HTTPS) && twilio_media_host?(uri.host)
    rescue URI::InvalidURIError
      false
    end

    def validate_twilio_media_redirect!(_old_env, new_env)
      return if valid_twilio_media_url?(new_env[:url].to_s)

      raise Faraday::ClientError, "Invalid Twilio media redirect URL"
    end

    def twilio_media_host?(host)
      return false unless host.present?

      normalized_host = host.downcase
      TWILIO_MEDIA_HOSTS.any? do |allowed_host|
        normalized_host == allowed_host || normalized_host.end_with?(".#{allowed_host}")
      end
    end
  end
end
