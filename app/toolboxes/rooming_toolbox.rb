class RoomingToolbox < ApplicationToolbox
  # Rooming for an event: rooms, who's in them, and who still needs a bed.
  # Built for porting a rooming sheet into Attend — call rooming_overview to map
  # names to participant_event_ids, then bulk_assign (which can create the rooms
  # as it fills them). Mirrors the rooming wizard: same manage_rooming? check,
  # same lock rule, same trans/nb + age-gap assignment flags.

  tool "Rooming overview for an event: plan status, every room with its occupants, " \
       "and the participants still needing a room. Use this to map a rooming sheet " \
       "to participant_event_ids before assigning.", access: :read, scope: "groups:read" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
  end
  def overview
    require_event!
    authorize! current_event, :show?
    plan = current_event.rooming_plan
    render json: {
      event: current_event.name,
      url: event_rooming_url(current_event),
      plan: plan && { status: plan.status, locked: plan.locked?, default_capacity: plan.room_capacity },
      rooms: current_event.rooms.ordered.map { |r| serialize_room(r) },
      unassigned: unassigned_registrations.map { |pe| serialize_person(pe) }
    }
  end

  tool "Create a room in an event.", access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :name, :string, "Room name/number", optional: true
    param :capacity, :integer, "Beds (defaults to the plan's room capacity)", optional: true
    param :staff_only, :boolean, "Staff room (no participants assigned here)", optional: true
    param :gender_label, :string, "Optional gender label", optional: true
    param :notes, :string, "Notes", optional: true
  end
  def create_room
    require_rooming!
    @room = current_event.rooms.create!(
      name: params[:name].presence,
      capacity: params[:capacity].presence || current_event.rooming_plan&.room_capacity || 2,
      staff_only: params[:staff_only] || false,
      gender_label: params[:gender_label].presence,
      notes: params[:notes].presence
    )
    render json: serialize_room(@room)
  end

  tool "Update a room's name, capacity, staff-only flag, or notes.", access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :room_id, :string, "Room ID"
    param :name, :string, "Room name/number", optional: true
    param :capacity, :integer, "Beds", optional: true
    param :staff_only, :boolean, "Staff room", optional: true
    param :gender_label, :string, "Gender label", optional: true
    param :notes, :string, "Notes", optional: true
  end
  def update_room
    require_rooming!
    @room = current_event.rooms.find(params[:room_id])
    @room.update!(params.permit(:name, :capacity, :staff_only, :gender_label, :notes).to_h.compact)
    render json: serialize_room(@room)
  end

  tool "Delete a room and clear its assignments.", access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :room_id, :string, "Room ID"
  end
  def delete_room
    require_rooming!
    @room = current_event.rooms.find(params[:room_id])
    @room.destroy!
    render json: { deleted: true, room_id: params[:room_id] }
  end

  tool "Assign one participant to a room (moves them if already assigned elsewhere).",
    access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :participant_event_id, :string, "ParticipantEvent ID"
    param :room_id, :string, "Room ID (or pass room_name)", optional: true
    param :room_name, :string, "Room name — resolved within the event", optional: true
  end
  def assign
    require_rooming!
    pe = current_event.participant_events.find(params[:participant_event_id])
    room = resolve_room!(params[:room_id], params[:room_name])
    ok, error = place(pe, room)
    halt error: error unless ok
    @assignment = pe.reload.room_assignment
    render json: { assigned: true, participant_event_id: pe.id, room: serialize_room(room.reload) }
  end

  tool "Remove a participant's room assignment (leaves them unassigned).",
    access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :participant_event_id, :string, "ParticipantEvent ID"
  end
  def unassign
    require_rooming!
    pe = current_event.participant_events.find(params[:participant_event_id])
    @assignment = pe.room_assignment
    @assignment&.destroy!
    render json: { unassigned: true, participant_event_id: pe.id }
  end

  tool "Bulk-assign rooms from a sheet in one call. Each entry names a room (existing " \
       "room_id, or room_name which is created when missing) and the participant_event_ids " \
       "to place in it. Returns per-room results so you can see what didn't fit.",
    access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :create_missing_rooms, :boolean, "Create rooms referenced by name that don't exist yet (default true)", optional: true
    param :assignments, [ :object ], "One entry per room" do
      param :room_id, :string, "Existing room ID", optional: true
      param :room_name, :string, "Room name (created if missing)", optional: true
      param :capacity, :integer, "Capacity to use when creating the room", optional: true
      param :participant_event_ids, [ :string ], "Registrations to place in this room"
    end
  end
  def bulk_assign
    require_rooming!
    create_missing = params[:create_missing_rooms] != false
    results = Array(params[:assignments]).map do |entry|
      process_bulk_entry(entry, create_missing)
    end
    render json: {
      event: current_event.name,
      rooms_touched: results.size,
      assigned: results.sum { |r| r[:assigned].to_i },
      failures: results.flat_map { |r| r[:failed] || [] },
      results: results
    }
  end

  private

  def require_rooming!
    require_event!
    authorize! current_event, :manage_rooming?
    if current_event.rooming_plan&.locked?
      halt error: "Rooming is locked for #{current_event.name}; unlock it in the wizard before editing."
    end
  end

  def resolve_room!(room_id, room_name)
    return current_event.rooms.find(room_id) if room_id.present?

    if room_name.present?
      room = current_event.rooms.find_by(name: room_name)
      return room if room

      halt error: "No room named #{room_name.inspect} in #{current_event.name}."
    end
    halt error: "Pass a room_id or room_name."
  end

  # Mirror the wizard's move_assignment: clear any existing assignment, enforce
  # staff/capacity rules, then create with the same flags. Returns [ok, error].
  def place(participant_event, room)
    participant_event.room_assignment&.destroy!
    room.reload
    return [ false, "#{room.display_name} is a staff room." ] if room.has_staff?
    return [ false, "#{room.display_name} is full." ] unless room.can_add_participants?

    RoomAssignment.create!(room: room, participant_event: participant_event, flags: assignment_flags(participant_event, room))
    [ true, nil ]
  end

  def process_bulk_entry(entry, create_missing)
    room = entry[:room_id].present? ? current_event.rooms.find_by(id: entry[:room_id]) : nil
    if room.nil? && entry[:room_name].present?
      room = current_event.rooms.find_by(name: entry[:room_name])
      if room.nil? && create_missing
        room = current_event.rooms.create!(
          name: entry[:room_name],
          capacity: entry[:capacity].presence || current_event.rooming_plan&.room_capacity || 2
        )
      end
    end
    label = room&.display_name || entry[:room_name] || entry[:room_id]
    return { room: label, assigned: 0, failed: [ { room: label, error: "room not found" } ] } if room.nil?

    assigned = 0
    failed = []
    Array(entry[:participant_event_ids]).each do |pe_id|
      pe = current_event.participant_events.find_by(id: pe_id)
      next failed << { room: label, participant_event_id: pe_id, error: "not registered for this event" } if pe.nil?

      ok, error = place(pe, room)
      ok ? assigned += 1 : failed << { room: label, participant_event_id: pe_id, error: error }
    end
    { room: label, room_id: room.id, assigned: assigned, failed: failed }
  end

  def assignment_flags(participant_event, room)
    flags = {}
    flags["trans_nb_pairing"] = true if participant_event.accommodation&.trans_or_nb?
    others = room.participant_events.where.not(id: participant_event.id)
    if others.any?
      ages = (others.map(&:age_on_event).compact + [ participant_event.age_on_event ].compact)
      flags["age_gap"] = ages.max - ages.min if ages.size >= 2 && (ages.max - ages.min) > 2
    end
    flags
  end

  def unassigned_registrations
    current_event.participant_events
      .where.not(status: %w[withdrawn rejected])
      .left_joins(:room_assignment).where(room_assignments: { id: nil })
      .includes(:participant)
  end

  def serialize_room(r)
    {
      id: r.id,
      name: r.display_name,
      capacity: r.capacity,
      occupancy: r.total_occupancy,
      spots_left: r.remaining_capacity,
      staff_only: r.staff_only,
      staff_names: r.staff_names.presence,
      gender_label: r.gender_label,
      occupants: r.occupants.map { |pe| serialize_person(pe) }
    }
  end

  def serialize_person(pe)
    p = pe.participant
    { participant_event_id: pe.id,
      name: [ p.preferred_name.presence || p.legal_first_name, p.legal_last_name ].join(" "),
      status: pe.status }
  end
end
