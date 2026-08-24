class IncidentsToolbox < ApplicationToolbox
  # Sensitive: incidents are filtered by visible_to_roles and the user's event role.
  # Everything here is gated on the safeguarding:* scope and IncidentPolicy.

  tool "List incidents for an event that you're permitted to see.",
    access: :read, scope: "safeguarding:read" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :status, :string, "Filter by status", enum: %w[open in_review closed], optional: true
    param :open_only, :boolean, "Only open/in-review incidents", optional: true
  end
  def index
    require_event!
    scope = policy_scope(current_event.incidents)
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.open_incidents if params[:open_only]
    render json: {
      event: current_event.name,
      incidents: scope.order(occurred_at: :desc, created_at: :desc).map { |i| serialize_incident(i) }
    }
  end

  tool "Show a single incident with its comments.", access: :read, scope: "safeguarding:read" do
    param :incident_id, :string, "Incident ID"
  end
  def show
    @incident = load_incident!
    authorize! @incident, :show?
    render json: serialize_incident(@incident, full: true)
  end

  tool "Report a new incident for an event.", access: :write, scope: "safeguarding:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :category, :string, "Category", enum: %w[safeguarding medical behavior other]
    param :severity, :string, "Severity", enum: %w[low medium high critical]
    param :summary, :string, "Short summary"
    param :details, :string, "Full details", optional: true
    param :location, :string, "Where it happened", optional: true
    param :occurred_at, :string, "When it happened (ISO8601)", optional: true
    param :participant_event_id, :string, "Related registration, if any", optional: true
    param :visible_to_roles, [ :string ], "Roles that may see this (defaults to event_admin + safeguarding_lead)", optional: true
  end
  def create
    require_event!
    @incident = current_event.incidents.new(
      params.permit(:category, :severity, :summary, :details, :location, :occurred_at,
                    :participant_event_id).to_h
    )
    @incident.reported_by_user_id = current_user.id
    @incident.visible_to_roles = params[:visible_to_roles].presence || %w[event_admin safeguarding_lead]
    authorize! @incident, :create?
    @incident.save!
    render json: serialize_incident(@incident, full: true)
  end

  tool "Update an incident's status or actions taken.", access: :write, scope: "safeguarding:write" do
    param :incident_id, :string, "Incident ID"
    param :status, :string, "New status", enum: %w[open in_review closed], optional: true
    param :actions_taken, :string, "Actions taken", optional: true
    param :severity, :string, "Severity", enum: %w[low medium high critical], optional: true
  end
  def update
    @incident = load_incident!
    authorize! @incident, :update?
    @incident.update!(params.permit(:status, :actions_taken, :severity).to_h)
    render json: serialize_incident(@incident, full: true)
  end

  tool "Add a comment to an incident.", access: :write, scope: "safeguarding:write" do
    param :incident_id, :string, "Incident ID"
    param :body, :string, "Comment text"
  end
  def add_comment
    @incident = load_incident!
    authorize! @incident, :show?
    @comment = @incident.incident_comments.create!(user: current_user, body: params[:body])
    render json: serialize_incident(@incident, full: true)
  end

  private

  # Set Current.event first — IncidentPolicy reads it to resolve the user's roles.
  def load_incident!
    incident = Incident.find(params[:incident_id])
    Current.event = incident.event
    unless current_user.can_access_event?(incident.event)
      halt error: "You don't have access to that event."
    end
    halt error: out_of_connection_scope(incident.event) unless connection_permits_event?(incident.event)
    incident
  end

  def serialize_incident(i, full: false)
    base = {
      id: i.id,
      category: i.category,
      severity: i.severity,
      status: i.status,
      summary: i.summary,
      occurred_at: i.occurred_at,
      location: i.location,
      url: incident_admin_url(i)
    }
    return base unless full

    base.merge(
      details: i.details,
      actions_taken: i.actions_taken,
      reported_by: i.reported_by_user&.display_name_or_fallback,
      visible_to_roles: i.visible_to_roles,
      participant_event_id: i.participant_event_id,
      comments: i.incident_comments.includes(:user).order(:created_at).map { |c|
        { author: c.user&.display_name_or_fallback, body: c.body, at: c.created_at }
      }
    )
  end
end
