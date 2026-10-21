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
    @preferred_name = @participant.greeting_name || "there"
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

  # The participant may be waiting on this to carry on, e.g. held at the
  # onboarding profile step until their birthday is corrected (see
  # OnboardingController#hold_at_profile_if_too_old), so the link goes back
  # into the wizard while they're still in it.
  def participant_approved(change_request:)
    @change_request = change_request
    @participant_event = change_request.participant_event
    @participant = @participant_event.participant
    @event = @participant_event.event
    @emailable = @participant
    @event_name = @event.name
    @preferred_name = @participant.greeting_name || "there"
    @support_email = @event.effective_support_email
    @request_label = SECTION_LABELS.fetch(change_request.kind)
    url_helpers = Rails.application.routes.url_helpers
    @in_onboarding = @participant_event.in_onboarding?
    @link = if @in_onboarding
      url_helpers.onboarding_url(event_id: @event.id, host: default_host, protocol: default_protocol)
    else
      url_helpers.dashboard_event_url(@participant_event, host: default_host, protocol: default_protocol)
    end

    mail(
      to: @participant.email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "Your #{@event_name} #{@request_label} was approved",
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
