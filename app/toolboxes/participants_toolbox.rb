class ParticipantsToolbox < ApplicationToolbox
  tool "Search participants by name or email, restricted to events you can access.",
    access: :read, scope: "participants:read" do
    param :query, :string, "Name or email substring (case-insensitive)"
    param :event_id, :string, "Restrict to a single event", optional: true
    param :event_slug, :string, "Restrict to a single event by slug", optional: true
    param :limit, :integer, "Max results (default 25, max 100)", optional: true, default: 25
  end
  def search
    scope = accessible_participants
    if (event = resolve_optional_event)
      scope = scope.where(id: event.participant_events.select(:participant_id))
    end
    q = "%#{params[:query].to_s.downcase}%"
    scope = scope.where(
      "LOWER(legal_first_name) LIKE :q OR LOWER(legal_last_name) LIKE :q OR " \
      "LOWER(preferred_name) LIKE :q OR LOWER(email) LIKE :q", q: q
    )
    limit = params[:limit].to_i.clamp(1, 100)
    render json: {
      count: scope.limit(limit).size,
      participants: scope.limit(limit).map { |p| serialize_participant(p) }
    }
  end

  tool "Show one participant's profile and every event they're registered for.",
    access: :read, scope: "participants:read" do
    param :participant_id, :string, "Participant ID"
  end
  def show
    @participant = accessible_participants.find(params[:participant_id])
    render json: serialize_participant(@participant, full: true)
  end

  tool "Update a participant's contact and profile details.", access: :write, scope: "participants:write" do
    param :participant_id, :string, "Participant ID"
    param :preferred_name, :string, "Preferred name", optional: true
    param :email, :string, "Primary email", optional: true
    param :phone, :string, "Phone number", optional: true
    param :pronouns, :string, "Pronouns", optional: true
    param :tshirt_size, :string, "T-shirt size", optional: true
    param :city, :string, "City", optional: true
    param :state, :string, "State/region", optional: true
    param :country_of_residence, :string, "Country of residence", optional: true
  end
  def update
    @participant = accessible_participants.find(params[:participant_id])
    @participant.update!(params.permit(:preferred_name, :email, :phone,
                                       :pronouns, :tshirt_size, :city, :state,
                                       :country_of_residence).to_h)
    render json: serialize_participant(@participant, full: true)
  end

  private

  # Participants reachable through the events the user can access.
  def accessible_participants
    return Participant.all if current_user.global_admin?

    Participant.where(id: ParticipantEvent.where(event_id: current_user.assigned_events.select(:id))
                                          .select(:participant_id))
  end

  def resolve_optional_event
    return nil if params[:event_id].blank? && params[:event_slug].blank?

    event = current_event
    halt error: "You don't have access to that event." unless event && current_user.can_access_event?(event)
    event
  end

  def serialize_participant(p, full: false)
    base = {
      id: p.id,
      name: [ p.preferred_name.presence || p.legal_first_name, p.legal_last_name ].join(" "),
      legal_name: [ p.legal_first_name, p.legal_last_name ].join(" "),
      email: p.email,
      pronouns: p.pronouns
    }
    return base unless full

    base.merge(
      phone: p.phone,
      slack_user_id: p.slack_user_id,
      date_of_birth: p.date_of_birth,
      city: p.city,
      state: p.state,
      country_of_residence: p.country_of_residence,
      tshirt_size: p.tshirt_size,
      registrations: p.participant_events
        .where(current_user.global_admin? ? {} : { event_id: current_user.assigned_events.select(:id) })
        .includes(:event).map { |pe|
          { participant_event_id: pe.id, event: pe.event.name, event_slug: pe.event.slug, status: pe.status }
        }
    )
  end
end
