class GuardianMailer < ApplicationMailer
  def invitation(guardian_participant_event:)
    @guardian_participant_event = guardian_participant_event
    @guardian = guardian_participant_event.guardian
    @participant = guardian_participant_event.participant_event.participant
    @event = guardian_participant_event.participant_event.event
    @emailable = @guardian

    # Last line of defense: callers check this too, but a job enqueued just
    # before the lock flipped would otherwise still send. Returning without
    # calling mail() yields a NullMail, so delivery is a no-op.
    if @event.guardian_invites_locked?
      Rails.logger.info("[GuardianMailer] invitation skipped for GPE #{guardian_participant_event.id}: guardian invites locked for event #{@event.id}")
      return
    end

    token = guardian_participant_event.generate_invite_token!
    guardian_participant_event.update!(invite_token_sent_at: Time.current)

    @first_name = @guardian.legal_first_name
    @child_first_name = @participant.legal_first_name
    @event_name = @event.name
    @location = [ @event.location_city, @event.location_country ].compact.join(", ")
    @portal_url = guardian_portal_url(token)
    @support_email = @event.effective_support_email

    mail(
      to: @guardian.email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "Complete #{@child_first_name}'s information for #{@event_name}",
      reply_to: @support_email
    )
  end

  def waiver_completion(guardian_participant_event:)
    @guardian_participant_event = guardian_participant_event
    @guardian = guardian_participant_event.guardian
    @participant_event = guardian_participant_event.participant_event
    @participant = @participant_event.participant
    @event = @participant_event.event
    @emailable = @guardian

    waiver_consent = @participant_event.consents.waiver.first
    freedom_waiver_consent = @participant_event.consents.freedom_waiver.first

    @event_name = @event.name
    @waiver_link = waiver_consent&.guardian_signing_url
    @freedom_waiver_link = freedom_waiver_consent&.guardian_signing_url
    @support_email = @event.effective_support_email

    mail(
      to: @guardian.email,
      cc: @participant.email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "Waiver(s) signed & completed",
      reply_to: @support_email
    )
  end

  def waiver_signing(guardian_participant_event:, consent:)
    @guardian_participant_event = guardian_participant_event
    @guardian = guardian_participant_event.guardian
    @participant_event = guardian_participant_event.participant_event
    @participant = @participant_event.participant
    @event = @participant_event.event
    @emailable = @guardian

    @first_name = @guardian.legal_first_name
    @child_first_name = @participant.preferred_name.presence || @participant.legal_first_name
    @event_name = @event.name
    @waiver_link = consent.guardian_signing_url
    @support_email = @event.effective_support_email

    mail(
      to: @guardian.email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "#{@child_first_name} signed their waiver - your signature needed for #{@event_name}",
      reply_to: @support_email
    )
  end

  # Their child opted into an activity after the guardian had already finished
  # the portal. Nothing brings them back on their own, so this is the only
  # thing that gets the activity's waiver signed.
  def optional_document_added(guardian_participant_event:, custom_document:)
    @guardian_participant_event = guardian_participant_event
    @guardian = guardian_participant_event.guardian
    @participant_event = guardian_participant_event.participant_event
    @participant = @participant_event.participant
    @event = @participant_event.event
    @emailable = @guardian

    if @event.guardian_invites_locked?
      Rails.logger.info("[GuardianMailer] optional_document_added skipped for GPE #{guardian_participant_event.id}: guardian invites locked for event #{@event.id}")
      return
    end

    token = guardian_participant_event.generate_invite_token!
    guardian_participant_event.update!(invite_token_sent_at: Time.current)

    @first_name = @guardian.legal_first_name
    @child_first_name = @participant.preferred_name.presence || @participant.legal_first_name
    @event_name = @event.name
    @document_name = custom_document.name
    @physical = custom_document.physical?
    @participant_uploads_first = custom_document.physical? && custom_document.participant_signs?
    @document_url = guardian_portal_document_url(token, custom_document)
    @support_email = @event.effective_support_email

    mail(
      to: @guardian.email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "#{@child_first_name} signed up for an optional activity at #{@event_name} - your signature needed",
      reply_to: @support_email
    )
  end

  def waiver_reset(guardian_participant_event:, waiver_type:)
    @guardian_participant_event = guardian_participant_event
    @guardian = guardian_participant_event.guardian
    @participant_event = guardian_participant_event.participant_event
    @participant = @participant_event.participant
    @event = @participant_event.event
    @emailable = @guardian

    # Now that expiry is measured purely from invite_token_sent_at, a reset sent
    # more than INVITE_VALIDITY after the original invite would email a link that
    # 404s on arrival. Stamping the send here restarts the window, matching what
    # #invitation and #optional_document_added already do.
    token = guardian_participant_event.generate_invite_token!
    guardian_participant_event.update!(invite_token_sent_at: Time.current)

    @first_name = @guardian.legal_first_name
    @child_first_name = @participant.preferred_name.presence || @participant.legal_first_name
    @event_name = @event.name
    @waiver_type = waiver_type
    @waiver_type_name = waiver_type == :freedom_waiver ? "Freedom Waiver" : "Waiver"
    @portal_url = guardian_portal_url(token)
    @support_email = @event.effective_support_email

    mail(
      to: @guardian.email,
      from: "Hack Club #{@event_name} <#{@support_email}>",
      subject: "Action Required: Please re-sign #{@child_first_name}'s #{@waiver_type_name} for #{@event_name}",
      reply_to: @support_email
    )
  end

  def portal_center_verification(email:, code:, guardian:)
    @code = code
    @emailable = guardian

    mail(
      to: email,
      subject: "#{code} is your Attend verification code"
    )
  end

  def self.should_notify_waiver_completion?(guardian_participant_event:)
    participant_event = guardian_participant_event.participant_event
    event = participant_event.event

    waiver_consent = participant_event.consents.waiver.first
    return false unless waiver_consent&.guardian_signed?

    if event.freedom_waivers_enabled?
      freedom_waiver_consent = participant_event.consents.freedom_waiver.first
      return false if freedom_waiver_consent.present? && !freedom_waiver_consent.guardian_signed?
    end

    true
  end

  private

  def guardian_portal_url(token)
    Rails.application.routes.url_helpers.guardian_portal_url(
      token: token,
      host: default_host,
      protocol: default_protocol
    )
  end

  def guardian_portal_document_url(token, custom_document)
    Rails.application.routes.url_helpers.guardian_portal_custom_document_url(
      token: token,
      custom_document_id: custom_document.id,
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
end
