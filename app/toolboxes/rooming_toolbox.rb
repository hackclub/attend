class RoomingToolbox < ApplicationToolbox
  # Rooming for an event: rooms, who's in them, and who still needs a bed.
  # Built for porting a rooming sheet into Attend — call rooming_overview to map
  # names to participant_event_ids, then bulk_assign (which can create the rooms
  # as it fills them). Mirrors the rooming wizard: same manage_rooming? check,
  # same lock rule, same trans/nb + age-gap assignment flags.
  #
  # Rooming happens per stay (during the event, the night before, the night
  # after). Every tool takes an optional stay_id; without one it uses the stay
  # during the event, or the only stay. It never creates a stay: an event with
  # none has nothing to room, and organizers add stays in the admin.

  STAY_PARAM_DESCRIPTION = "Stay ID from rooming_overview. Defaults to the stay during the event, or the only stay".freeze

  tool "Rooming overview for an event: its stays, then for one stay the plan status, " \
       "every room with its occupants, and the participants still needing a room. Use " \
       "this to map a rooming sheet to participant_event_ids before assigning.", access: :read, scope: "groups:read" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :stay_id, :string, STAY_PARAM_DESCRIPTION, optional: true
  end
  def overview
    require_event!
    authorize! current_event, :show?
    stays = current_event.rooming_contexts.ordered.to_a
    if stays.empty?
      render json: {
        event: current_event.name,
        stays: [],
        note: "#{current_event.name} has no stays, so nobody is roomed. Organizers add stays at #{event_stays_url(current_event)}."
      }
      return
    end
    if params[:stay_id].blank? && stays.none?(&:main?) && !stays.one?
      render json: {
        event: current_event.name,
        stays: stays.map { |s| serialize_stay(s) },
        note: "Several stays and none during the event: call again with a stay_id."
      }
      return
    end

    stay = current_stay
    plan = stay.rooming_plan
    render json: {
      event: current_event.name,
      stays: stays.map { |s| serialize_stay(s) },
      stay: serialize_stay(stay),
      url: event_rooming_url(current_event, stay: stay),
      plan: plan && { status: plan.status, locked: plan.locked?, default_capacity: plan.room_capacity },
      rooms: stay.rooms.ordered.map { |r| serialize_room(r) },
      unassigned: unassigned_registrations.map { |pe| serialize_person(pe) }
    }
  end

  tool "Create a room in a stay.", access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :stay_id, :string, STAY_PARAM_DESCRIPTION, optional: true
    param :name, :string, "Room name/number", optional: true
    param :capacity, :integer, "Beds (defaults to the plan's room capacity)", optional: true
    param :staff_only, :boolean, "Staff room (no participants assigned here)", optional: true
    param :gender_label, :string, "Optional gender label", optional: true
    param :notes, :string, "Notes", optional: true
  end
  def create_room
    require_rooming!
    @room = current_stay.rooms.create!(
      name: params[:name].presence,
      capacity: params[:capacity].presence || default_capacity,
      staff_only: params[:staff_only] || false,
      gender_label: params[:gender_label].presence,
      notes: params[:notes].presence
    )
    render json: serialize_room(@room)
  end

  tool "Update a room's name, capacity, staff-only flag, or notes.", access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :stay_id, :string, STAY_PARAM_DESCRIPTION, optional: true
    param :room_id, :string, "Room ID"
    param :name, :string, "Room name/number", optional: true
    param :capacity, :integer, "Beds", optional: true
    param :staff_only, :boolean, "Staff room", optional: true
    param :gender_label, :string, "Gender label", optional: true
    param :notes, :string, "Notes", optional: true
  end
  def update_room
    require_rooming!
    @room = current_stay.rooms.find(params[:room_id])
    @room.update!(params.permit(:name, :capacity, :staff_only, :gender_label, :notes).to_h.compact)
    render json: serialize_room(@room)
  end

  tool "Delete a room and clear its assignments.", access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :stay_id, :string, STAY_PARAM_DESCRIPTION, optional: true
    param :room_id, :string, "Room ID"
  end
  def delete_room
    require_rooming!
    @room = current_stay.rooms.find(params[:room_id])
    @room.destroy!
    render json: { deleted: true, room_id: params[:room_id] }
  end

  tool "Assign one participant to a room in a stay (moves them if already in another " \
       "room in that stay). In a stay that's only for people on its list, they're " \
       "added to the list too.", access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :stay_id, :string, STAY_PARAM_DESCRIPTION, optional: true
    param :participant_event_id, :string, "ParticipantEvent ID"
    param :room_id, :string, "Room ID (or pass room_name)", optional: true
    param :room_name, :string, "Room name — resolved within the stay", optional: true
  end
  def assign
    require_rooming!
    pe = current_event.participant_events.find(params[:participant_event_id])
    room = resolve_room!(params[:room_id], params[:room_name])
    ok, error = place(pe, room)
    halt error: error unless ok
    @assignment = stay_assignment(pe)
    render json: { assigned: true, participant_event_id: pe.id, stay: serialize_stay(current_stay), room: serialize_room(room.reload) }
  end

  tool "Remove a participant's room assignment in a stay (leaves them unassigned there).",
    access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :stay_id, :string, STAY_PARAM_DESCRIPTION, optional: true
    param :participant_event_id, :string, "ParticipantEvent ID"
  end
  def unassign
    require_rooming!
    pe = current_event.participant_events.find(params[:participant_event_id])
    @assignment = stay_assignment(pe)
    @assignment&.destroy!
    render json: { unassigned: true, participant_event_id: pe.id, stay: serialize_stay(current_stay) }
  end

  tool "Bulk-assign rooms in a stay from a sheet in one call. Each entry names a room " \
       "(existing room_id, or room_name which is created when missing) and the " \
       "participant_event_ids to place in it. Returns per-room results so you can see " \
       "what didn't fit.",
    access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :stay_id, :string, STAY_PARAM_DESCRIPTION, optional: true
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
      stay: serialize_stay(current_stay),
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
    if current_stay.rooming_plan&.locked?
      halt error: "Rooming for #{current_stay.name} is locked; unlock it in the wizard before editing."
    end
  end

  # The stay named by stay_id, else the one during the event, else the only
  # one. Never creates a stay.
  def current_stay
    @current_stay ||= begin
      stays = current_event.rooming_contexts.ordered.to_a
      if params[:stay_id].present?
        stays.find { |s| s.id == params[:stay_id] } ||
          halt(error: "#{current_event.name} has no stay #{params[:stay_id]}; rooming_overview lists its stays.")
      elsif stays.empty?
        halt error: "#{current_event.name} has no stays, so there's nothing to room. Organizers add stays at #{event_stays_url(current_event)}."
      else
        stays.find(&:main?) || (stays.one? && stays.first) ||
          halt(error: "#{current_event.name} has several stays and none during the event; pass stay_id. " \
                      "Stays: #{stays.map { |s| "#{s.name} (#{s.id})" }.join(', ')}.")
      end
    end
  end

  def default_capacity
    current_stay.rooming_plan&.room_capacity || 2
  end

  def stay_assignment(participant_event)
    participant_event.room_assignments.find_by(rooming_context: current_stay)
  end

  def resolve_room!(room_id, room_name)
    return current_stay.rooms.find(room_id) if room_id.present?

    if room_name.present?
      room = current_stay.rooms.find_by(name: room_name)
      return room if room

      halt error: "No room named #{room_name.inspect} in #{current_stay.name}."
    end
    halt error: "Pass a room_id or room_name."
  end

  # Mirror the wizard's move_assignment: clear any existing assignment in this
  # stay, enforce staff/capacity rules, then create with the same flags. In a
  # list-only stay, someone given a room joins the list, or removing them from
  # the list later wouldn't free the room. Returns [ok, error].
  def place(participant_event, room)
    stay_assignment(participant_event)&.destroy!
    room.reload
    return [ false, "#{room.display_name} is a staff room." ] if room.has_staff?
    return [ false, "#{room.display_name} is full." ] unless room.can_add_participants?

    if current_stay.eligible_only?
      Rooming::Roster.new(current_stay, added_by: current_user).add(participant_event, source: :manual)
    end
    RoomAssignment.create!(room: room, participant_event: participant_event, flags: assignment_flags(participant_event, room))
    [ true, nil ]
  end

  def process_bulk_entry(entry, create_missing)
    room = entry[:room_id].present? ? current_stay.rooms.find_by(id: entry[:room_id]) : nil
    if room.nil? && entry[:room_name].present?
      room = current_stay.rooms.find_by(name: entry[:room_name])
      if room.nil? && create_missing
        room = current_stay.rooms.create!(
          name: entry[:room_name],
          capacity: entry[:capacity].presence || default_capacity
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

  # Registrations still without a room in this stay: everyone registered for a
  # stay that takes everyone, or just the people on its list.
  def unassigned_registrations
    scope = current_event.participant_events
      .where.not(status: %w[withdrawn rejected])
      .where.not(id: current_stay.room_assignments.select(:participant_event_id))
      .includes(:participant)
    scope = scope.where(id: current_stay.roster_entries.select(:participant_event_id)) if current_stay.eligible_only?
    scope
  end

  def serialize_stay(stay)
    {
      id: stay.id,
      name: stay.name,
      when: stay.kind_label,
      who: stay.everyone? ? "everyone with accommodation" : "only people on its list",
      starts_on: stay.starts_on,
      ends_on: stay.ends_on
    }
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
    { participant_event_id: pe.id, name: participant_name(p), status: pe.status }
  end
end
