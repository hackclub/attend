class ParticipantMailer < ApplicationMailer
  def invitation(email:, name: nil, event:, participant: nil, group_ids: nil)
    @participant = participant
    @event = event
    @emailable = participant

    invitation = Invitation.pending.find_or_create_by!(email: (participant&.email || email).downcase, event: event)
    invitation.assign_group_ids!(group_ids) if group_ids.is_a?(Array)
    # This is the moment the participant learns about the event, so it is
    # where the send is recorded — a held invitation stops being held here.
    invitation.mark_sent!

    @first_name = if participant
      participant.preferred_name.presence || participant.legal_first_name
    else
      (name.presence || invitation.name.presence)&.split&.first || email.split("@").first
    end

    @event_name = event.name
    @event_dates = event.formatted_date_range
    @location = invitation_location(event)
    @registration_deadline = invitation_deadline(event)
    @travel_required = event.travel_enabled?
    @accommodation_required = event.accommodation_enabled?
    @guardian_requirement = guardian_requirement(participant, event)
    @onboarding_url = onboarding_url(invitation.token)
    @support_email = event.effective_support_email

    mail(
      to: participant&.email || email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "Complete your registration for #{@event_name}",
      reply_to: @support_email
    )
  end

  def travel_update_reminder(participant_event:)
    @participant_event = participant_event
    @participant = participant_event.participant
    @event = participant_event.event
    @emailable = @participant

    @preferred_name = @participant.preferred_name.presence || @participant.legal_first_name
    @event_name = @event.name
    @action_link = travel_update_url(participant_event)

    mail(
      to: @participant.email,
      from: "Leo (Hack Club) <leo@hackclub.com>",
      subject: "[#{@event_name}] I don't have your travel info!",
      reply_to: "attend@hackclub.com"
    )
  end

  def waiver_ready(participant_event:)
    @participant_event = participant_event
    @participant = participant_event.participant
    @event = participant_event.event
    @emailable = @participant

    waiver_consent = @participant_event.consents.waiver.first
    @waiver_link = waiver_consent&.participant_signing_url || waiver_page_url
    completion = RegistrationCompletionPresenter.new(@participant_event, viewer: :participant)
    @waiver_is_final_task = completion.outstanding_tasks.none? do |task|
      task.consent != waiver_consent
    end
    @preferred_name = @participant.preferred_name.presence || @participant.legal_first_name
    @event_name = @event.name
    @support_email = @event.effective_support_email

    mail(
      to: @participant.email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "Sign your waiver for #{@event_name}",
      reply_to: @support_email
    )
  end

  def adult_waiver_completion(participant_event:)
    @participant_event = participant_event
    @participant = participant_event.participant
    @event = participant_event.event
    @emailable = @participant

    waiver_consent = @participant_event.consents.waiver.first
    freedom_waiver_consent = @participant_event.consents.freedom_waiver.first

    @event_name = @event.name
    @waiver_link = waiver_consent&.document_url
    @freedom_waiver_link = freedom_waiver_consent&.document_url
    @support_email = @event.effective_support_email

    mail(
      to: @participant.email,
      subject: "Waiver completed for #{@event_name}",
      reply_to: @support_email
    )
  end

  def registration_confirmed(participant_event:)
    @participant_event = participant_event
    @participant = participant_event.participant
    @event = participant_event.event
    @emailable = @participant
    @preferred_name = @participant.preferred_name.presence || @participant.legal_first_name
    @event_name = @event.name
    @dashboard_link = event_dashboard_url(participant_event)
    @support_email = @event.effective_support_email

    mail(
      to: @participant.email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "Your entry ticket is ready for #{@event_name}",
      reply_to: @support_email
    )
  end

  def new_document_ready(participant_event:)
    @participant_event = participant_event
    @participant = participant_event.participant
    @event = participant_event.event
    @emailable = @participant

    @pending_documents = participant_event.pending_custom_documents
    @preferred_name = @participant.preferred_name.presence || @participant.legal_first_name
    @event_name = @event.name
    @documents_link = event_dashboard_url(participant_event)
    @support_email = @event.effective_support_email

    mail(
      to: @participant.email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "A new document needs signing for #{@event_name}",
      reply_to: @support_email
    )
  end

  def slack_link_reminder(participant_event:)
    @participant_event = participant_event
    @participant = participant_event.participant
    @event = participant_event.event
    @emailable = @participant

    @preferred_name = @participant.preferred_name.presence || @participant.legal_first_name
    @event_name = @event.name
    @support_email = @event.effective_support_email

    token = @participant_event.signed_id(purpose: :slack_connect)
    @slack_connect_url = slack_connect_url(token, host: default_host, protocol: default_protocol)

    mail(
      to: @participant.email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "Connect your Slack account for #{@event_name}",
      reply_to: @support_email
    )
  end

  private

  def invitation_location(event)
    [ event.venue_name, event.location_address, event.location_city, event.location_country ]
      .filter_map(&:presence)
      .uniq
      .join(", ")
  end

  def invitation_deadline(event)
    event.registration_close_at&.in_time_zone(event.event_time_zone)&.strftime("%B %-d, %Y at %-I:%M %p %Z")
  end

  def guardian_requirement(participant, event)
    return :unknown_age unless participant&.date_of_birth

    participant.minor_on?(event.starts_at&.in_time_zone(event.event_time_zone)&.to_date || Date.current) ? :minor : :adult
  end

  def onboarding_url(token)
    Rails.application.routes.url_helpers.onboarding_url(
      host: default_host,
      protocol: default_protocol,
      invite: token
    )
  end

  def event_dashboard_url(participant_event)
    Rails.application.routes.url_helpers.dashboard_event_url(
      participant_event,
      host: default_host,
      protocol: default_protocol
    )
  end

  def travel_update_url(participant_event)
    Rails.application.routes.url_helpers.dashboard_event_travel_edit_url(
      participant_event,
      host: default_host,
      protocol: default_protocol
    )
  end

  def default_host
    ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "localhost:3000" }
  end

  def default_protocol
    Rails.env.local? ? "http" : "https"
  end

  def waiver_page_url
    Rails.application.routes.url_helpers.onboarding_waiver_url(
      event_id: @participant_event.event_id,
      host: default_host,
      protocol: default_protocol
    )
  end
end
