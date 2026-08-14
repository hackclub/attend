class MessageMailer < ApplicationMailer
  def broadcast(delivery:)
    @delivery = delivery
    @message = delivery.message
    @event = delivery.event
    @emailable = delivery

    @body_html = @message.body_as_html.html_safe
    @message_url = message_url_for(delivery)
    @footer_text = "You're receiving this message because you're a confirmed attendee at #{@event.name}."
    @support_email = @event.effective_support_email

    subject = @message.subject.presence || "You have a new message from #{@event.name}"

    mail(
      to: delivery.recipient_email,
      from: "Hack Club #{@event.name} <#{@support_email}>",
      subject: subject,
      reply_to: @support_email
    )
  end

  private

  def message_url_for(delivery)
    Rails.application.routes.url_helpers.dashboard_message_url(
      delivery,
      host: default_host,
      protocol: default_protocol
    )
  end

  def default_host
    ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "attend.hackclub.com" }
  end

  def default_protocol
    Rails.env.local? ? "http" : "https"
  end
end
