class RegistrationCorrectionMailer < ApplicationMailer
  SECTION_LABELS = {
    "contact" => "contact information",
    "health" => "health and accessibility information",
    "emergency" => "emergency contact information",
    "signed_identity" => "signed identity request",
    "guardian" => "guardian replacement request",
    "support" => "private support request"
  }.freeze

  def staff_notification(recipient:, participant_event:, section:)
    @recipient = recipient
    @participant_event = participant_event
    @event = participant_event.event
    @emailable = recipient
    @section_label = SECTION_LABELS.fetch(section)
    @participant_url = Rails.application.routes.url_helpers.admin_event_participant_url(
      @event,
      @participant_event,
      host: default_host,
      protocol: default_protocol
    )

    mail(
      to: recipient.email,
      subject: "Registration #{@section_label} changed for #{@event.name}"
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
