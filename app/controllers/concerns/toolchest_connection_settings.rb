# Adds the per-connection privacy choices to the MCP OAuth consent screen: which
# events the client may reach, and whether its responses are anonymized.
#
# Toolchest's authorizations controller owns the grant/token dance, so this only
# brackets it — it loads the event list for the form, refuses a POST that asks
# for specific events without naming any, and writes McpConnectionSetting once
# the grant has actually been issued. Included from an initializer, the same way
# ToolchestRedirectFormAction is.
module ToolchestConnectionSettings
  extend ActiveSupport::Concern

  included do
    before_action :load_mcp_connection_settings, only: [ :new, :create ]
    before_action :require_mcp_event_selection, only: :create
    after_action :persist_mcp_connection_settings, only: :create
  end

  private

  def load_mcp_connection_settings
    return if @current_resource_owner.nil?

    @mcp_connection = McpConnectionSetting.find_by(
      application_id: @application&.id,
      resource_owner_id: current_resource_owner_id
    )
    @mcp_events = mcp_selectable_events
    # Re-authorizing is the only way to widen access, so the form starts from
    # what the connection already has rather than from wide open.
    @mcp_event_scope = params[:mcp_event_scope].presence ||
      (@mcp_connection&.restricted_to_events? ? "selected" : "all")
    @mcp_selected_event_ids = if params[:mcp_event_ids].present?
      Array(params[:mcp_event_ids]).map(&:to_s)
    else
      @mcp_connection&.restricted_to_events? ? @mcp_connection.events.pluck(:id).map(&:to_s) : []
    end
    @mcp_anonymize = if params.key?(:mcp_event_scope)
      ActiveModel::Type::Boolean.new.cast(params[:mcp_anonymize]).present?
    else
      @mcp_connection&.anonymize? || false
    end
  end

  # Events the user could hand this client. Global admins can reach everything,
  # so their list is every event; everyone else sees the events they staff.
  def mcp_selectable_events
    user = @current_resource_owner
    return Event.none unless user.respond_to?(:assigned_events)

    scope = user.try(:global_admin?) ? Event.all : user.assigned_events
    scope.order(Arel.sql("starts_at DESC NULLS LAST"), :name)
  end

  # An empty allowlist would mean "no events", which is never what someone
  # ticking "only these events" meant to say. Send them back to the form.
  def require_mcp_event_selection
    return unless params[:mcp_event_scope] == "selected"
    return if permitted_mcp_event_ids.any?

    @mcp_settings_error = "Pick at least one event, or give access to all of them."
    new
    render :new unless performed?
  end

  # Only rows the grant actually reached — a denial or a failed authorize_link?
  # check redirects with an error instead of a code, and must not save anything.
  def persist_mcp_connection_settings
    return if @application.nil? || @current_resource_owner.nil?
    return unless response.redirect? && response.location.to_s.include?("code=")

    settings = McpConnectionSetting.find_or_initialize_by(
      application_id: @application.id,
      resource_owner_id: current_resource_owner_id
    )
    event_ids = params[:mcp_event_scope] == "selected" ? permitted_mcp_event_ids : []
    anonymize = ActiveModel::Type::Boolean.new.cast(params[:mcp_anonymize]).present?

    if anonymize && !settings.anonymize?
      settings.anonymize = true
      settings.anonymize_enabled_at = Time.current
      settings.anonymize_enabled_by = "consent"
    elsif !anonymize
      settings.anonymize = false
      settings.anonymize_enabled_at = nil
      settings.anonymize_enabled_by = nil
    end

    # all_events flips last: the row can't validate as event-restricted until the
    # events it points at exist.
    settings.transaction do
      settings.all_events = true
      settings.save!
      settings.mcp_connection_events.where.not(event_id: event_ids).delete_all
      (event_ids - settings.mcp_connection_events.pluck(:event_id)).each do |event_id|
        settings.mcp_connection_events.create!(event_id: event_id)
      end
      settings.update!(all_events: event_ids.empty?)
    end
  rescue ActiveRecord::ActiveRecordError => e
    # The client already has its code by now; losing the settings row would
    # silently hand it wider access than the user asked for, so shout loudly.
    Rails.logger.error("[mcp] failed to save connection settings: #{e.class} - #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    raise
  end

  # Never trust the posted ids: intersect them with the events this user could
  # actually delegate.
  def permitted_mcp_event_ids
    @permitted_mcp_event_ids ||= begin
      requested = Array(params[:mcp_event_ids]).map(&:to_s).compact_blank.uniq
      requested.any? ? mcp_selectable_events.where(id: requested).pluck(:id) : []
    end
  end
end
