class ParticipantEventsToolbox < ApplicationToolbox
  # A participant_event is one person's registration for one event. This is where
  # status, check-in, travel, accommodation, and medical data all hang.

  include AirportPickupMarkable

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
    # first scan in the context marks the airport pickup and mints an NFC badge
    # token, and Scan's after_create_commit puts it on the live scan feed.
    first_scan_in_context = @participant_event.scans.where(scan_context: scan_context).none?
    # @record makes the audit log point at the scan rather than guessing.
    @record = @participant_event.scans.create!(
      user: current_user,
      scan_context: scan_context,
      scanned_at: Time.current,
      source: "manual"
    )

    if first_scan_in_context
      mark_airport_pickup(@participant_event, current_user)
      @participant_event.ensure_nfc_badge_token! if event.nfc_badges_enabled?
    end

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

  private

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
