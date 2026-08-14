class SupportTicketMailer < ApplicationMailer
  NOTIFICATION_RECIPIENT = "leo@hackclub.com".freeze

  def new_chat(ticket_id:, message_id:)
    @ticket = Ticket.find(ticket_id)
    @message = TicketMessage.find(message_id)
    @ticket_url = Rails.application.routes.url_helpers.support_ticket_url(
      @ticket,
      host: default_host,
      protocol: default_protocol
    )

    channel_label = @ticket.channel.to_s.upcase
    subject_line = "New #{channel_label} chat from #{@ticket.phone_number}"

    mail(
      to: NOTIFICATION_RECIPIENT,
      subject: subject_line,
      reply_to: "team@hackclub.com"
    )
  end

  private

  def default_host
    ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "attend.hackclub.com" }
  end

  def default_protocol
    Rails.env.local? ? "http" : "https"
  end
end
