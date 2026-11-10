class ParticipantEventsToolbox < ApplicationToolbox
  # A participant_event is one person's registration for one event. This is where
  # status, check-in, travel, accommodation, and medical data all hang.

  tool "List registrations for an event, optionally filtered by status.",
    access: :read, scope: "participants:read" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :status, :string, "Filter by status",
      enum: %w[invited in_progress awaiting_guardian complete withdrawn rejected], optional: true
    param :limit, :integer, "Max results (default 50, max 200)", optional: true, default: 50
  end
  def index
    require_event!
    authorize! current_event, :show?
    # scans/scan_context feed the checked_in flag on every serialized row.
    scope = current_event.participant_events.includes(:participant, scans: :scan_context)
    scope = scope.where(status: params[:status]) if params[:status].present?
    limit = params[:limit].to_i.clamp(1, 200)
    render json: {
      event: current_event.name,
      total: scope.count,
      registrations: scope.limit(limit).map { |pe| serialize_registration(pe) }
    }
  end

  tool "Show a registration's full state: profile, status, onboarding, guardians, and what data is on file.",
    access: :read, scope: "participants:read" do
    param :participant_event_id, :string, "ParticipantEvent ID"
  end
  def show
    @participant_event = ParticipantEvent.find(params[:participant_event_id])
    authorize! @participant_event, :show?
    pe = @participant_event
    render json: serialize_registration(pe).merge(
      onboarding_completed_at: pe.onboarding_completed_at,
      onboarding_step: pe.onboarding_step,
      checked_in_at: pe.check_in_time,
      guardians: pe.guardian_participant_events.includes(:guardian).map { |gpe|
        { name: person_name(gpe.guardian&.full_name), primary: gpe.is_primary_guardian, status: gpe.status }
      },
      data_on_file: {
        travel_inbound: pe.travel_inbound.present?,
        travel_outbound: pe.travel_outbound.present?,
        accommodation: pe.accommodation.present?,
        medical: pe.medical.present?,
        dietary: pe.dietary.present?,
        accessibility: pe.accessibility.present?,
        safeguarding_info: pe.safeguarding_info.present?,
        consents: pe.consents.count
      }
    )
  end

  tool "Change a registration's status (e.g. confirm, withdraw, reject).",
    access: :write, scope: "participants:write" do
    param :participant_event_id, :string, "ParticipantEvent ID"
    param :status, :string, "New status",
      enum: %w[invited in_progress awaiting_guardian complete withdrawn rejected]
  end
  def set_status
    @participant_event = ParticipantEvent.find(params[:participant_event_id])
    authorize! @participant_event, :update?
    @participant_event.update!(status: params[:status])
    render json: serialize_registration(@participant_event)
  end

  tool "Check a participant in to the event (records a check-in scan, same as the scanner).",
    access: :write, scope: "participants:write" do
    param :participant_event_id, :string, "ParticipantEvent ID"
  end
  def check_in
    @participant_event = ParticipantEvent.find(params[:participant_event_id])
    authorize! @participant_event, :update?

    event = @participant_event.event
    scan_context = event.scan_contexts.find_by(checks_in: true)
    if scan_context.nil?
      halt error: "#{event.name} has no check-in scan context configured — add one under the event's scan contexts first."
    end

    # Check-in is a scan, so this goes through the same path the scanners use:
    # first scan in the context mints an NFC badge token, and Scan's
    # after_create_commit puts it on the live scan feed.
    first_scan_in_context = @participant_event.scans.where(scan_context: scan_context).none?
    # @record makes the audit log point at the scan rather than guessing.
    @record = @participant_event.scans.create!(
      user: current_user,
      scan_context: scan_context,
      scanned_at: Time.current,
      source: "manual"
    )

    if first_scan_in_context
      @participant_event.ensure_nfc_badge_token! if event.nfc_badges_enabled?
    end

    TravelCalendar::JourneyCache.clear(event)

    # An earlier scan wins on time, so report what #show would.
    render json: serialize_registration(@participant_event).merge(
      checked_in_at: @participant_event.check_in_time,
      scan_context: scan_context.name
    )
  end

  tool "Show a participant's travel legs (inbound and outbound).",
    access: :read, scope: "participants:read" do
    param :participant_event_id, :string, "ParticipantEvent ID"
  end
  def travel
    @participant_event = ParticipantEvent.find(params[:participant_event_id])
    authorize! @participant_event, :view_travel?
    render json: {
      participant_event_id: @participant_event.id,
      travel: @participant_event.travels.includes(:travel_legs).map { |t| serialize_travel(t) }
    }
  end

  tool "Show a participant's accommodation and rooming details.",
    access: :read, scope: "participants:read" do
    param :participant_event_id, :string, "ParticipantEvent ID"
  end
  def accommodation
    @participant_event = ParticipantEvent.find(params[:participant_event_id])
    authorize! @participant_event, :view_accommodation?
    a = @participant_event.accommodation
    return render(json: { accommodation: nil }) if a.nil?

    render json: { accommodation: {
      venue_name: a.venue_name,
      check_in_date: a.check_in_date,
      check_out_date: a.check_out_date,
      room_type_preference: a.room_type_preference,
      gender_identity: a.gender_identity,
      gender_identity_other: a.gender_identity_other,
      gender_bucket: a.gender_bucket,
      preferred_roommate_genders: a.preferred_roommate_genders,
      assigned_room: a.assigned_room,
      rooming_exempt: a.rooming_exempt,
      accessibility_needs: a.accessibility_needs,
      notes: a.notes
    } }
  end

  # --- Guardians -------------------------------------------------------------
  # The same operations as the guardian card on the admin participant page.
  # Guardian contact details are PII, so these need a role that can see it.

  tool "List a registration's guardians with their contact details and invite state.",
    access: :read, scope: "participants:read" do
    param :participant_event_id, :string, "ParticipantEvent ID"
  end
  def guardians
    load_participant_event!
    authorize! @participant_event, :show?
    require_pii_access!("see guardian contact details")

    render json: {
      participant_event_id: @participant_event.id,
      requires_guardian: @participant_event.requires_guardian?,
      guardian_invites_locked: @participant_event.event.guardian_invites_locked?,
      guardians: @participant_event.guardian_participant_events.includes(:guardian).map { |gpe| serialize_guardian_link(gpe) }
    }
  end

  tool "Correct a guardian's name, email or phone (e.g. a mistyped address). If the email changes " \
       "and the guardian hasn't finished, their next invite is a fresh one. Does not send anything — " \
       "follow with participant_events_resend_guardian_invite.",
    access: :write, scope: "participants:write" do
    param :participant_event_id, :string, "ParticipantEvent ID"
    param :guardian_participant_event_id, :string, "Guardian link ID, from participant_events_guardians"
    param :email, :string, "New email", optional: true
    param :legal_first_name, :string, "Legal first name", optional: true
    param :legal_last_name, :string, "Legal last name", optional: true
    param :phone, :string, "Phone number (E.164)", optional: true
  end
  def update_guardian
    load_participant_event!
    authorize! @participant_event, :manage_guardians?
    require_pii_access!("edit guardian contact details")

    gpe = @participant_event.guardian_participant_events.find(params[:guardian_participant_event_id])
    @guardian = gpe.guardian
    attributes = params.permit(:email, :legal_first_name, :legal_last_name, :phone).to_h.compact_blank
    halt error: "Pass at least one of email, legal_first_name, legal_last_name, phone." if attributes.empty?

    # Mirrors Admin::GuardiansController#update: a guardian can't share the
    # participant's phone (the email check lives on the model).
    participant_phone = @participant_event.participant.phone
    if attributes["phone"].present? && participant_phone.present? &&
        PhoneNormalizer.normalize(attributes["phone"]) == participant_phone
      halt error: "Guardian phone cannot be the same as the participant's phone number."
    end

    # A guardian row is shared by every registration it's linked to (siblings),
    # so say so rather than silently changing their details too.
    other_registrations = @guardian.guardian_participant_events.where.not(id: gpe.id).count

    old_email = @guardian.email
    @guardian.update!(attributes)
    gpe.update!(invite_token_sent_at: nil) if @guardian.email != old_email && !gpe.completed?

    render json: {
      guardian: serialize_guardian_link(gpe.reload),
      also_linked_to_other_registrations: other_registrations,
      next_step: "Call participant_events_resend_guardian_invite to email the guardian."
    }
  end

  tool "Email a guardian their portal invite again (sends a real email).",
    access: :write, scope: "participants:write" do
    param :participant_event_id, :string, "ParticipantEvent ID"
    param :guardian_participant_event_id, :string, "Guardian link ID, from participant_events_guardians"
  end
  def resend_guardian_invite
    load_participant_event!
    authorize! @participant_event, :manage_guardians?

    if @participant_event.event.guardian_invites_locked?
      halt error: "Guardian invites are currently locked for #{@participant_event.event.name}."
    end

    @guardian_participant_event = @participant_event.guardian_participant_events.find(params[:guardian_participant_event_id])
    guardian = @guardian_participant_event.guardian
    if guardian.email_undeliverable?
      halt error: "The guardian's email is bouncing — correct it with participant_events_update_guardian first."
    end

    @guardian_participant_event.update!(invite_token_sent_at: nil)
    GuardianMailer.invitation(guardian_participant_event: @guardian_participant_event).deliver_later

    render json: { sent: true, to: guardian.email, guardian: serialize_guardian_link(@guardian_participant_event) }
  end

  # --- Consents / waivers ----------------------------------------------------

  tool "List a registration's consents and waivers with their signing state (who it's pending on, " \
       "failure reason, signed timestamps).",
    access: :read, scope: "participants:read" do
    param :participant_event_id, :string, "ParticipantEvent ID"
  end
  def consents
    load_participant_event!
    authorize! @participant_event, :show?

    render json: {
      participant_event_id: @participant_event.id,
      consents_url: registration_url(@participant_event, page: :consents),
      consents: @participant_event.consents.includes(:custom_document).map { |c| serialize_consent(c) }
    }
  end

  tool "Re-issue a registration's waiver or freedom waiver: discards the current DocuSeal submission " \
       "(including any signature or delegation), reopens the guardian portal, and emails whoever signs " \
       "(guardian for minors, participant otherwise). Sends a real email.",
    access: :write, scope: "participants:write" do
    param :participant_event_id, :string, "ParticipantEvent ID"
    param :waiver_type, :string, "Which waiver", enum: %w[waiver freedom_waiver]
  end
  def reset_waiver
    load_participant_event!
    authorize! @participant_event, :reset_waiver?

    waiver_type = params[:waiver_type].to_s
    halt error: "waiver_type must be waiver or freedom_waiver." unless %w[waiver freedom_waiver].include?(waiver_type)

    @consent = @participant_event.consents.find_by(consent_type: waiver_type)
    halt error: "No #{waiver_type.humanize.downcase} found on this registration." if @consent.nil?

    # Same steps as Admin::ParticipantsController#reset_waiver / #reset_freedom_waiver.
    # No reload before rendering: the audit log reads @consent.previous_changes.
    @consent.reset_for_reissue!
    @participant_event.reopen_guardian_portal_access! if @participant_event.requires_guardian?
    emailed = send_waiver_reset_email(waiver_type.to_sym)

    render json: {
      consent: serialize_consent(@consent),
      emailed: emailed,
      note: "A new document is generated when they next open the portal."
    }
  end

  private

  def load_participant_event!
    @participant_event = ParticipantEvent.includes(:event, :participant).find(params[:participant_event_id])
    # Several ParticipantEventPolicy checks compare against Current.event, the
    # way the admin UI scopes them.
    Current.event = @participant_event.event
  end

  def require_pii_access!(what)
    halt error: "Your role can't #{what}." unless view_pii?
  end

  def serialize_guardian_link(gpe)
    g = gpe.guardian
    {
      guardian_participant_event_id: gpe.id,
      name: person_name(g&.full_name),
      email: g&.email,
      phone: (g&.phone if view_pii?),
      relationship: gpe.relationship,
      primary: gpe.is_primary_guardian,
      status: gpe.status,
      invite_sent_at: gpe.invite_token_sent_at,
      email_undeliverable: g&.email_undeliverable? || false
    }
  end

  def serialize_consent(c)
    {
      consent_id: c.id,
      type: c.consent_type,
      name: c.display_name,
      status: c.status,
      pending_on: c.pending_on,
      failure_reason: c.failure_reason,
      sent_at: c.sent_at,
      participant_signed_at: c.participant_signed_at,
      guardian_signed_at: c.guardian_signed_at,
      signed_at: c.signed_at
    }
  end

  # Returns who was emailed, for the response.
  def send_waiver_reset_email(waiver_type)
    if @participant_event.requires_guardian?
      gpe = @participant_event.guardian_participant_events.first
      return "nobody (no guardian on file)" unless gpe

      GuardianMailer.waiver_reset(guardian_participant_event: gpe, waiver_type: waiver_type).deliver_later
      "guardian"
    else
      ParticipantMailer.waiver_ready(participant_event: @participant_event).deliver_later
      "participant"
    end
  end

  def serialize_registration(pe)
    p = pe.participant
    {
      participant_event_id: pe.id,
      participant_id: pe.participant_id,
      name: participant_name(p),
      email: p.email,
      event: pe.event.name,
      event_slug: pe.event.slug,
      status: pe.status,
      checked_in: pe.check_in_time.present?,
      url: registration_url(pe),
      public_profile_url: public_profile_url(p)
    }
  end

  def serialize_travel(t)
    {
      direction: t.direction,
      mode: t.mode,
      carrier: t.carrier,
      flight_number: t.flight_number,
      departure_city: t.departure_city,
      arrival_city: t.arrival_city,
      # For flights the real times live on the individual legs; first_departure_time
      # and last_arrival_time fall back to the legs, so these match what the UI shows
      # instead of the (usually empty) flat columns.
      departure_time: t.first_departure_time,
      arrival_time: t.last_arrival_time,
      unaccompanied_minor: t.is_unaccompanied_minor,
      notes: t.notes,
      legs: t.travel_legs.map { |l| serialize_travel_leg(l) }
    }
  end

  def serialize_travel_leg(l)
    {
      flight_code: l.flight_code,
      departure_airport: l.departure_airport,
      arrival_airport: l.arrival_airport,
      departure_time: l.departure_time,
      arrival_time: l.arrival_time
    }
  end
end
