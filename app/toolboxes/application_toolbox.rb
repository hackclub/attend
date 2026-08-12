class ApplicationToolbox < Toolchest::Toolbox
  # The MCP counterpart to ApplicationController. Every tool call runs here as the
  # user the access token was issued for, with that user's real permissions.
  #
  # auth.resource_owner — the authenticated User (see config/initializers/toolchest.rb)
  # auth.scopes         — scopes the user consented to for this client
  # auth.token          — the raw OAuth access token record

  helper_method :current_user, :current_event, :global_admin?

  before_action :establish_current_context
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

  private

  # Mirror ApplicationController#set_current_attributes so PaperTrail versions and
  # anything reading Current.* are attributed to the acting user, not a null actor.
  def establish_current_context
    Current.user = current_user
    Current.request_id = "mcp-#{auth&.token&.id}"
    PaperTrail.request.whodunnit = current_user&.id
  end

  def require_event!
    halt error: "Pass an event_id or event_slug — use events_list to find one." if current_event.nil?
    unless current_user.can_access_event?(current_event)
      halt error: "You don't have access to #{current_event.name}."
    end
    Current.event = current_event
  end

  # Pundit, callable without a controller context.
  def authorize!(record, query = nil)
    Pundit.authorize(current_user, record, query || "#{action_name}?".to_sym)
  end

  def policy_scope(scope)
    Pundit.policy_scope!(current_user, scope)
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
