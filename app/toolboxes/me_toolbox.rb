class MeToolbox < ApplicationToolbox
  # me_anonymize changes the connection's own settings, not event data, so it
  # stays callable on a connection that is already read-only for everything else.
  skip_before_action :refuse_writes_when_anonymized!, only: :anonymize

  tool "Show the current authenticated user: their name, email, global role, and the events they can access.",
    access: :read, scope: %w[events:read participants:read] do
  end
  def show
    render json: {
      id: current_user.id,
      name: person_name(current_user.display_name_or_fallback),
      email: current_user.email,
      global_role: current_user.global_role,
      global_admin: current_user.global_admin?,
      events: current_user.event_role_assignments.includes(:event).map { |ra|
        { id: ra.event_id, name: ra.event.name, slug: ra.event.slug, role: ra.role,
          url: event_admin_url(ra.event) }
      },
      accessible_scopes: auth&.scopes,
      connection: serialize_connection,
      urls: {
        # Where a participant turns their own public profile on — the only way a
        # /p/:slug profile link ever comes into existence.
        profile_settings: attend_url("/dashboard/profile"),
        participant_dashboard: attend_url("/dashboard")
      }
    }
  end

  tool "Anonymize this connection: names come back as initials and emails, phone numbers " \
       "and addresses are stripped from every response, for this client from now on. " \
       "It also makes the connection read-only. This cannot be undone from here — only the " \
       "account holder can lift it, by reconnecting the client in Attend.",
    access: :write, scope: %w[events:read participants:read] do
    param :confirm, :boolean, "Must be true — this is not reversible from here"
  end
  def anonymize
    halt error: "Pass confirm: true to anonymize this connection. It can't be undone from here." unless params[:confirm]

    connection = mcp_connection || create_connection_settings!
    already_on = connection.anonymize?
    connection.anonymize!(:mcp)
    @record = connection

    render json: {
      anonymized: true,
      changed: !already_on,
      note: already_on ? "This connection was already anonymized." :
        "Names are now initials and contact details are stripped. This connection is now read-only.",
      connection: serialize_connection(connection.reload)
    }
  end

  private

  # An anonymize call may be the first thing that needs a settings row — clients
  # authorized before per-connection settings existed don't have one.
  def create_connection_settings!
    application_id = auth&.token&.application_id
    halt error: "This connection isn't an OAuth client, so it has no settings to change." if application_id.blank?

    McpConnectionSetting.create!(application_id: application_id, resource_owner_id: current_user.id.to_s)
  end

  def serialize_connection(connection = mcp_connection)
    anonymized = connection&.anonymize? || false
    unrestricted = connection.nil? || connection.all_events?

    {
      client: auth&.token&.application&.name,
      anonymized: anonymized,
      writes_allowed: !anonymized,
      event_scope: unrestricted ? "all events you can access" : connection.events.order(:name).pluck(:name)
    }
  end
end
