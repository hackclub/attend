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

  def participant_follow_up(change_request:)
    @change_request = change_request
    @participant_event = change_request.participant_event
    @participant = @participant_event.participant
    @event = @participant_event.event
    @emailable = @participant
    @event_name = @event.name
    @preferred_name = @participant.preferred_name.presence || @participant.legal_first_name
    @support_email = @event.effective_support_email
    @dashboard_link = Rails.application.routes.url_helpers.dashboard_event_registration_change_request_url(
      @participant_event,
      change_request,
      host: default_host,
      protocol: default_protocol
    )

    mail(
      to: @participant.email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "More information needed for your #{@event_name} registration",
      reply_to: @support_email
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
