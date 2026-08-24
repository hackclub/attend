Toolchest.configure do |config|
  config.server_name = "Attend"
  config.server_description = "Hack Club's event attendance, participant, and safeguarding platform"
  config.server_instructions = <<~INSTRUCTIONS.squish
    You are acting on behalf of an Attend staff user. Attend manages events and their
    participants, travel, accommodation, rooming, groups, messaging, incidents, and
    safeguarding. Most data is scoped to a single event: call events_list to discover
    events and use the event_id (or slug) the user is working in. Participants are people
    registered for an event; a participant_event is one person's registration for one
    event. Medical, safeguarding, and incident data is sensitive and only visible to users
    with the right event role — expect permission errors and relay them plainly rather than
    retrying. Prefer the read tools to orient yourself before making any changes. To port a
    rooming sheet, call rooming_overview first to map names to participant_event_ids and see
    existing rooms, then rooming_bulk_assign (it can create rooms by name as it fills them).
    When you tell a human about a record, give them its link, not its ID: read tools return a
    `url` on the records they serialize, links_participant turns a participant_id into every
    link that exists for that person, and links_patterns has the URL templates for anything
    else. Public participant profiles (/p/:slug) are opt-in, so many people simply don't have
    one — never invent a profile URL or any other path.
  INSTRUCTIONS

  config.auth = :oauth
  config.mount_path = "/mcp"

  # Unauthenticated browsers hitting the OAuth consent screen are sent here. The home
  # page renders the "Sign in with Hack Club" button when signed out.
  config.login_path = "/"

  # Identify the logged-in user during the OAuth consent screen (Devise/Warden session).
  config.current_user_for_oauth do |request|
    request.env["warden"]&.user
  end

  # MCP is staff-only. Anyone who isn't staff (participants, guardians, signed-up
  # users with no role) can't reach the consent screen: toolchest bounces them back
  # to the client with an access_denied error on both GET and POST /oauth/authorize.
  config.authorize_link { |user| user.present? && user.admin? }

  # Resolve an access token back to the Attend user it was issued for. Everything a
  # toolbox does runs as this user, with this user's real permissions. Tokens issued
  # before a user lost their staff roles stop resolving here, so demoting someone
  # kills their MCP access without anyone having to revoke tokens by hand.
  config.authenticate do |token|
    user = User.find_by(id: token.resource_owner_id)
    user if user&.admin?
  end

  # Scopes the user consents to when connecting a client. These gate which tools are
  # offered; the user's actual event roles and Pundit policies still enforce access
  # per-request inside each toolbox.
  config.scopes = {
    "events:read"        => "View events, staff, and event settings",
    "events:write"       => "Create and update events and event settings",
    "participants:read"  => "View participants, travel, accommodation, and registrations",
    "participants:write" => "Add, edit, and withdraw participants and their travel/accommodation",
    "groups:read"        => "View groups, rooming plans, and room assignments",
    "groups:write"       => "Manage groups, rooming, and room assignments",
    "messages:read"      => "View messages and delivery status",
    "messages:write"     => "Compose and send messages and blasts",
    "tickets:read"       => "View support tickets, messages, and notes",
    "tickets:write"      => "Reply to, assign, and resolve support tickets",
    "medical:read"       => "View medical, dietary, and accessibility records (sensitive)",
    "medical:write"      => "Edit medical, dietary, and accessibility records (sensitive)",
    "safeguarding:read"  => "View incidents and safeguarding information (sensitive)",
    "safeguarding:write" => "Create and update incidents and safeguarding information (sensitive)"
  }

  config.optional_scopes = true

  # Never hand a client more than the account itself could ever use. Fine-grained,
  # per-event enforcement still happens inside the toolboxes via the event roles.
  config.allowed_scopes_for do |user, requested_scopes|
    # Belt and braces with authorize_link above — a non-staff account gets nothing.
    next [] unless user&.admin?

    allowed = requested_scopes

    # Global read-only accounts can never write anything.
    allowed -= allowed.grep(/:write\z/) if user.read_only?

    # Only users who hold a safeguarding/admin role somewhere may touch safeguarding
    # or incident data at all.
    unless user.global_admin? || user.event_role_assignments.exists?(role: %w[event_admin safeguarding_lead])
      allowed -= allowed.grep(/\Asafeguarding:/)
    end

    allowed
  end
end

require "mcp"
MCP.configure do |mcp|
  mcp.exception_reporter = lambda do |exception, _server_context|
    Rails.logger.error "[mcp] #{exception.class}: #{exception.message}\n#{exception.backtrace&.first(10)&.join("\n")}"
    Sentry.capture_exception(exception) if defined?(Sentry)
  end
end
