class EventsToolbox < ApplicationToolbox
  tool "List all events the current user can access, most recent first.",
    access: :read, scope: "events:read" do
    param :query, :string, "Filter by name or slug (case-insensitive substring)", optional: true
    param :drafts_only, :boolean, "Only events still in setup (not yet completed)", optional: true
  end
  def index
    events = policy_scope(Event).order(starts_at: :desc)
    if params[:query].present?
      q = "%#{params[:query].downcase}%"
      events = events.where("LOWER(name) LIKE :q OR LOWER(slug) LIKE :q", q: q)
    end
    events = events.where(setup_completed_at: nil) if params[:drafts_only]
    render json: { events: events.map { |e| serialize_event(e) } }
  end

  tool "Show a single event's full details, feature flags, and headline counts.",
    access: :read, scope: "events:read" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
  end
  def show
    require_event!
    authorize! current_event, :show?
    render json: serialize_event(current_event, full: true)
  end

  tool "Create a new event. Global admins only.", access: :write, scope: "events:write" do
    param :name, :string, "Event name"
    param :slug, :string, "URL slug (unique)"
    param :starts_at, :string, "Start (ISO8601)", optional: true
    param :ends_at, :string, "End (ISO8601)", optional: true
    param :timezone, :string, "IANA timezone, e.g. America/New_York", optional: true
    param :location_city, :string, "City", optional: true
    param :location_country, :string, "Country", optional: true
    param :venue_name, :string, "Venue", optional: true
    param :support_email, :string, "Support email (@hackclub.com or @events.hackclub.com)"
  end
  def create
    @event = Event.new(params.permit(*WRITABLE).to_h)
    authorize! @event, :create?
    @event.save!
    render json: serialize_event(@event, full: true)
  end

  tool "Update an existing event's core details or feature flags.", access: :write, scope: "events:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :name, :string, "Event name", optional: true
    param :starts_at, :string, "Start (ISO8601)", optional: true
    param :ends_at, :string, "End (ISO8601)", optional: true
    param :timezone, :string, "IANA timezone", optional: true
    param :location_city, :string, "City", optional: true
    param :location_country, :string, "Country", optional: true
    param :venue_name, :string, "Venue", optional: true
    param :support_email, :string, "Support email (@hackclub.com or @events.hackclub.com)", optional: true
    param :travel_enabled, :boolean, "Enable travel collection", optional: true
    param :accommodation_enabled, :boolean, "Enable accommodation", optional: true
    param :groups_enabled, :boolean, "Enable groups", optional: true
    param :nfc_badges_enabled, :boolean, "Enable NFC badges", optional: true
  end
  def update
    require_event!
    @event = current_event
    authorize! @event, :update?
    @event.update!(params.permit(*WRITABLE, *FLAGS).to_h)
    render json: serialize_event(@event, full: true)
  end

  WRITABLE = %i[name slug starts_at ends_at timezone location_city location_country
                location_address venue_name support_email registration_open_at
                registration_close_at].freeze
  FLAGS = %i[travel_enabled accommodation_enabled groups_enabled nfc_badges_enabled
             visa_options_enabled roommate_preferences_enabled freedom_waivers_enabled].freeze

  private

  def serialize_event(e, full: false)
    base = {
      id: e.id,
      name: e.name,
      slug: e.slug,
      starts_at: e.starts_at,
      ends_at: e.ends_at,
      timezone: e.timezone,
      location: [ e.venue_name, e.location_city, e.location_country ].compact_blank.join(", "),
      draft: e.setup_completed_at.nil?
    }
    return base unless full

    base.merge(
      support_email: e.support_email,
      registration_open_at: e.registration_open_at,
      registration_close_at: e.registration_close_at,
      participant_count: e.participant_events.count,
      confirmed_count: e.participant_events.where(status: "complete").count,
      features: {
        travel: e.travel_enabled?,
        accommodation: e.accommodation_enabled?,
        groups: e.groups_enabled?,
        nfc_badges: e.nfc_badges_enabled?,
        visa_options: e.visa_options_enabled?
      },
      your_role: current_user.role_for_event(e) || (current_user.global_admin? ? "global_admin" : nil)
    )
  end
end
