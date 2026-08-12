class EmailLogObserver
  def self.delivered_email(message)
    return unless message.perform_deliveries

    mailer_class, mailer_action = extract_mailer_info(message)

    email_log = EmailLog.create!(
      to_address: Array(message.to).join(", "),
      from_address: Array(message.from).join(", "),
      subject: message.subject,
      mailer_class: mailer_class,
      mailer_action: mailer_action,
      postmark_message_id: extract_postmark_message_id(message),
      emailable: message.instance_variable_get(:@_emailable),
      event: message.instance_variable_get(:@_event),
      status: "sent",
      body: extract_body(message)
    )

    email_log.email_log_events.create!(
      event_type: "sent",
      occurred_at: Time.current,
      metadata: {}
    )

    Rails.logger.info("[EmailLog] Logged email #{email_log.id} to #{email_log.to_address}")
  rescue => e
    Rails.logger.error("[EmailLog] Failed to log email: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
  end

  def self.extract_mailer_info(message)
    delivery_handler = message.delivery_handler
    if delivery_handler.is_a?(Class)
      mailer_class = delivery_handler.name
    else
      mailer_class = delivery_handler.to_s
    end

    mailer_action = message.instance_variable_get(:@_mailer_action) || "unknown"

    [ mailer_class, mailer_action ]
  end

  def self.extract_postmark_message_id(message)
    message["X-PM-Message-Id"]&.value || message["Message-ID"]&.value
  end

  def self.extract_body(message)
    html_body = if message.html_part
      message.html_part.body.decoded
    elsif message.content_type&.include?("text/html")
      message.body.decoded
    end

    return nil unless html_body

    doc = Nokogiri::HTML(html_body)
    container = doc.at_css(".container")
    return html_body unless container

    container.css(".signature, .footer").each(&:remove)

    container.inner_html.strip
  rescue => e
    Rails.logger.error("[EmailLog] Failed to extract body: #{e.message}")
    nil
  end
end
