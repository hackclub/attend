class ApplicationToolbox < Toolchest::Toolbox
  # The MCP counterpart to ApplicationController. Every tool call runs here as the
  # user the access token was issued for, with that user's real permissions.
  #
  # auth.resource_owner — the authenticated User (see config/initializers/toolchest.rb)
  # auth.scopes         — scopes the user consented to for this client
  # auth.token          — the raw OAuth access token record

  # Every serialized record carries the URL of the page it lives on, so agents
  # hand humans links instead of bare IDs.
  include AttendUrls

  helper_method :current_user, :current_event, :global_admin?, :participant_name, :person_name

  before_action :require_staff!
  before_action :establish_current_context
  before_action :refuse_writes_when_anonymized!
  after_action :audit_write!

  rescue_from Pundit::NotAuthorizedError do |_e|
    render_error "You are not authorized to do that."
  end

  rescue_from ActiveRecord::RecordNotFound do |e|
    render_error "Couldn't find that #{e.model&.underscore&.humanize&.downcase || "record"}."
  end

  rescue_from ActiveRecord::RecordInvalid do |e|
    render_errors e.record
  end

  rescue_from Toolchest::ParameterMissing do |e|
    render_error "Missing required parameter: #{e.message}"
  end

  def current_user = auth&.resource_owner

  def global_admin? = current_user&.global_admin?

  # Event-scoped tools accept either an event_id or event_slug param. Resolve it,
  # confirm the user can reach it, and expose it as current_event / Current.event.
  def current_event
    return @current_event if defined?(@current_event)

    @current_event =
      if params[:event_id].present?
        Event.find(params[:event_id])
      elsif params[:event_slug].present?
        Event.find_by!(slug: params[:event_slug])
      end
  end

  # Per-connection restrictions the user set when they authorized this client
  # (see McpConnectionSetting). nil when the client predates the setting or the
  # user left it unrestricted.
  def mcp_connection
    return @mcp_connection if defined?(@mcp_connection)

    @mcp_connection = McpConnectionSetting.for(auth&.token&.application_id, current_user)
  end

  def anonymized? = mcp_connection&.anonymize? || false

  # Whether this account may see participants' exact dates of birth, addresses,
  # and phone numbers. Participants here aren't scoped to one event, so a
  # PII-restricted role on one event doesn't hide anything for someone who is
  # ops elsewhere.
  def view_pii?
    return @view_pii if defined?(@view_pii)

    @view_pii = current_user&.can_view_participant_pii? || false
  end

  # nil means "no connection-level restriction" — every event the user can reach.
  def permitted_event_ids
    return @permitted_event_ids if defined?(@permitted_event_ids)

    @permitted_event_ids = mcp_connection&.permitted_event_ids
  end

  # The events this call may touch: the user's own access, narrowed by whatever
  # the connection was scoped to.
  def accessible_events
    scope = global_admin? ? Event.all : current_user.assigned_events
    permitted_event_ids ? scope.where(id: permitted_event_ids) : scope
  end

  def accessible_event?(event)
    event.present? && current_user.can_access_event?(event) && connection_permits_event?(event)
  end

  def connection_permits_event?(event)
    permitted_event_ids.nil? || permitted_event_ids.include?(event&.id)
  end

  # A participant's name, reduced to initials on an anonymized connection.
  def participant_name(participant)
    return nil if participant.nil?

    person_name([ participant.preferred_name.presence || participant.legal_first_name,
                  participant.legal_last_name ].compact_blank.join(" "))
  end

  def person_name(name)
    anonymized? ? Mcp::ResponseFilter.initials(name) : name
  end

  # Runs every response through the privacy filter on an anonymized connection.
  # Doing it here rather than in each serializer means a new tool is anonymized
  # by default instead of by remembering to be.
  def render(action_or_template = nil, json: nil, text: nil)
    json = Mcp::ResponseFilter.call(json) if anonymized? && (json.is_a?(Hash) || json.is_a?(Array))
    super
  end

  private

  # MCP is a staff-only surface. The consent screen and token resolution already
  # gate on this (config/initializers/toolchest.rb), so getting here without a
  # staff user means a token outlived its owner's roles — refuse every tool call.
  def require_staff!
    return if current_user&.admin?

    halt error: "MCP access is limited to Attend staff."
  end

  # Mirror ApplicationController#set_current_attributes so PaperTrail versions and
  # anything reading Current.* are attributed to the acting user, not a null actor.
  def establish_current_context
    Current.user = current_user
    Current.request_id = "mcp-#{auth&.token&.id}"
    PaperTrail.request.whodunnit = current_user&.id
  end

  # Anonymized connections are read-only: an agent that can't see who someone is
  # has no business changing their record, and blocking writes also closes the
  # write-then-read path back to the values we just stripped.
  def refuse_writes_when_anonymized!
    return unless anonymized?
    return if @_tool_definition&.access_level == :read

    halt error: <<~MESSAGE.squish
      This connection is anonymized, so it can read data but not change it —
      #{@_tool_definition&.tool_name || action_name} was not run and nothing was modified.
      Anonymization also replaces names with initials and removes emails, phone
      numbers and addresses from every response. To let this agent make changes,
      the account holder needs to disconnect it under Profile → Connections in
      Attend and reconnect it without anonymization; it can't be lifted from here.
    MESSAGE
  end

  def require_event!
    halt error: "Pass an event_id or event_slug — use events_index to find one." if current_event.nil?
    unless current_user.can_access_event?(current_event)
      halt error: "You don't have access to #{current_event.name}."
    end
    halt error: out_of_connection_scope(current_event) unless connection_permits_event?(current_event)
    Current.event = current_event
  end

  # Pundit, callable without a controller context. The connection's event
  # allowlist is checked alongside it: Pundit answers "may this user?", this
  # answers "may this connection?".
  def authorize!(record, query = nil)
    result = Pundit.authorize(current_user, record, query || "#{action_name}?".to_sym)
    guard_connection_event!(record)
    result
  end

  def policy_scope(scope)
    narrow_to_connection_events(Pundit.policy_scope!(current_user, scope))
  end

  def guard_connection_event!(record)
    return if permitted_event_ids.nil?
    return unless record.is_a?(Event) || record.respond_to?(:event)

    event = record.is_a?(Event) ? record : record.event
    # An event-scoped record with no event — a support ticket nobody has filed
    # under an event yet — sits outside every allowlist rather than inside all
    # of them.
    if event.nil?
      return unless record.class.column_names.include?("event_id")

      halt error: "This connection is scoped to #{connection_event_names.to_sentence}, and this " \
                  "#{record.class.model_name.human.downcase} isn't linked to any event."
    end

    halt error: out_of_connection_scope(event) unless permitted_event_ids.include?(event.id)
  end

  # Event-restricted connections see only their events' rows. Records with no
  # event at all (an unlinked support ticket, say) are outside the allowlist too.
  def narrow_to_connection_events(scope)
    return scope if permitted_event_ids.nil?

    klass = scope.respond_to?(:klass) ? scope.klass : nil
    return scope if klass.nil?
    return scope.where(id: permitted_event_ids) if klass == Event
    return scope unless klass.column_names.include?("event_id")

    scope.where(event_id: permitted_event_ids)
  end

  def out_of_connection_scope(event)
    "This connection is scoped to #{connection_event_names.to_sentence} and can't reach #{event.name}. " \
      "The account holder can change that under Profile → Connections in Attend."
  end

  def connection_event_names
    names = mcp_connection&.events&.order(:name)&.pluck(:name)
    names.presence || [ "no events" ]
  end

  # Log mutating tool calls so MCP activity lands in the same audit trail as the
  # admin UI. Read tools declare `access: :read` and are skipped.
  def audit_write!
    return if @_tool_definition&.access_level == :read
    return if current_user.nil?

    record = find_changed_record
    return if record.nil?

    changed = record.respond_to?(:previous_changes) ? record.previous_changes.except("updated_at", "created_at") : {}
    changed = redact_encrypted_audit_fields(record, changed)

    AuditLog.log!(
      action: audit_action_for(record),
      record: record,
      actor: current_user,
      event: (Current.event unless Current.event&.destroyed?),
      changed_fields: changed,
      metadata: { source: "mcp", toolbox: controller_name, tool: action_name, scopes: auth&.scopes }
    )
  rescue => e
    Rails.logger.error("[mcp] audit log failed: #{e.class} - #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    raise if Rails.env.local?
  end

  # Map a tool action onto AuditLog's constrained action enum. The specific tool is
  # always preserved in metadata[:tool]; this just picks the coarse CRUD bucket.
  def audit_action_for(record)
    return :record_destroy if record.destroyed?
    return :record_create if action_name == "create"

    :record_update
  end

  IGNORED_CHANGE_KEYS = %w[updated_at created_at].freeze

  def find_changed_record
    candidates = instance_variables.filter_map do |ivar|
      value = instance_variable_get(ivar)
      next unless value.is_a?(ActiveRecord::Base)
      next unless value.respond_to?(:previous_changes)

      relevant = value.previous_changes.except(*IGNORED_CHANGE_KEYS)
      next unless value.destroyed? || relevant.any?

      [ ivar, value, relevant.size ]
    end
    return nil if candidates.empty?

    explicit = candidates.find { |ivar, _, _| ivar == :@record }
    return explicit[1] if explicit

    candidates.max_by { |_, _, size| size }[1]
  end

  def redact_encrypted_audit_fields(record, changed_fields)
    encrypted = record.class.try(:encrypted_attributes)
    return changed_fields if encrypted.blank?

    names = encrypted.map(&:to_s)
    changed_fields.to_h { |field, change| [ field, names.include?(field.to_s) ? "[REDACTED]" : change ] }
  end
end
