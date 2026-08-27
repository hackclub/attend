module Admin
  class BaseController < ApplicationController
    before_action :authenticate_user!
    before_action :authorize_admin_access
    before_action :set_current_event_from_session
    before_action :switch_event_if_needed
    before_action :ensure_can_access_current_event, if: -> { current_event.present? }
    after_action :log_admin_action, unless: -> { request.get? }

    layout "admin"

    helper_method :current_event, :available_events, :can_view_participant_pii?

    # Views that render an exact date of birth or a home address gate on this;
    # PII-restricted roles (Limited) get age and no address instead.
    def can_view_participant_pii?
      return @can_view_participant_pii if defined?(@can_view_participant_pii)

      @can_view_participant_pii = current_user&.can_view_participant_pii?(current_event) || false
    end

    def current_event
      @current_event
    end

    def available_events
      @available_events ||= policy_scope(Event)
        .includes(logo_attachment: :blob, event_series: { logo_attachment: :blob })
        .order(starts_at: :desc)
    end

    private

    def authorize_admin_access
      unless current_user&.admin?
        redirect_to root_path, alert: "You are not authorized to access this area."
      end
    end

    def set_current_event_from_session
      if session[:current_event_id].present?
        @current_event = Event.find_by(id: session[:current_event_id])
        Current.event = @current_event
      end
    end

    def switch_event_if_needed
      return if params[:event_slug].blank?

      url_event = Event.find_by(slug: params[:event_slug])
      return unless url_event
      return if current_event&.id == url_event.id

      if current_user.global_admin? || current_user.can_access_event?(url_event)
        set_current_event(url_event)
      end
    end

    def set_current_event(event)
      @current_event = event
      Current.event = event

      # Turbo prefetches links on hover; the prefetched page still renders
      # with its event, but must not switch the picker's selected event.
      session[:current_event_id] = event&.id unless prefetch_request?
    end

    def prefetch_request?
      request.headers["X-Sec-Purpose"].to_s.include?("prefetch") ||
        request.headers["Sec-Purpose"].to_s.include?("prefetch") ||
        request.headers["Purpose"].to_s.include?("prefetch")
    end

    def require_event_selected
      unless current_event
        redirect_to admin_events_path, alert: "Please select an event first."
      end
    end

    def can_access_current_event?
      return true if current_user.global_admin?
      return false unless current_event

      current_user.can_access_event?(current_event)
    end

    def ensure_can_access_current_event
      return if can_access_current_event?

      session[:current_event_id] = nil
      Current.event = nil
      @current_event = nil

      redirect_to admin_events_path,
        alert: "You no longer have access to that event."
    end

    # Let a new staff member know they've been given access. Skipped when an
    # admin assigns a role to themselves — they already know.
    def notify_new_staff_member(assignment)
      return if assignment.user_id == current_user&.id

      EventStaffMailer.added_to_event(assignment: assignment, added_by: current_user)
        .deliver_later
    rescue => e
      Rails.logger.error("[EventStaffMailer] Failed to enqueue invite for assignment #{assignment.id}: #{e.class} - #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
    end

    def log_admin_action
      return unless current_user

      changed_record = find_changed_record
      record = changed_record || @record || @event || @participant_event
      # Skip audit logging for actions without a record (e.g., impersonation)
      return if record.nil?

      changed_fields = if changed_record
        changed_record.previous_changes.except("updated_at", "created_at")
      elsif record.respond_to?(:previous_changes)
        record.previous_changes.except("updated_at", "created_at")
      else
        {}
      end
      changed_fields = redact_encrypted_audit_fields(record, changed_fields)

      event_for_log = current_event unless current_event&.destroyed?

      AuditLog.log!(
        action: action_name,
        record: record,
        actor: current_user,
        event: event_for_log,
        changed_fields: changed_fields,
        metadata: {
          ip: request.remote_ip,
          user_agent: request.user_agent,
          controller: controller_name,
          params: request.filtered_parameters.except("controller", "action", "authenticity_token")
        }
      )
    rescue => e
      Rails.logger.error("[Security] Failed to create audit log: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace&.first(5)&.join("\n"))

      # Report to error tracking service if available
      Sentry.capture_exception(e) if defined?(Sentry)

      # Re-raise in development/test so failures are noticed immediately
      raise if Rails.env.local?
    end

    AUDIT_IGNORED_CHANGE_KEYS = %w[updated_at created_at].freeze

    # Scan controller instance variables for an ActiveRecord object that was
    # actually mutated this request. This lets every admin update get audit-
    # logged with a real diff without each controller having to set @record.
    def find_changed_record
      candidates = instance_variables.filter_map do |ivar|
        value = instance_variable_get(ivar)
        next unless value.is_a?(ActiveRecord::Base)
        next unless value.respond_to?(:previous_changes)

        relevant_changes = value.previous_changes.except(*AUDIT_IGNORED_CHANGE_KEYS)
        was_destroyed = value.destroyed?
        next unless was_destroyed || relevant_changes.any?

        [ ivar, value, relevant_changes.size, was_destroyed ]
      end

      return nil if candidates.empty?

      # Prefer @record if explicitly set; otherwise prefer the record with the
      # most field changes; destroyed records (no previous_changes) come last.
      explicit = candidates.find { |ivar, _, _, _| ivar == :@record }
      return explicit[1] if explicit

      candidates.max_by { |_, _, change_count, _| change_count }[1]
    end

    # Values of `encrypts`-declared attributes are plaintext in
    # previous_changes; keep them out of the audit_logs jsonb so encrypted-at-
    # rest content (incident narratives, medical notes, etc.) never lands
    # there readable.
    def redact_encrypted_audit_fields(record, changed_fields)
      encrypted = record.class.try(:encrypted_attributes)
      return changed_fields if encrypted.blank?

      encrypted_names = encrypted.map(&:to_s)
      changed_fields.to_h do |field, change|
        [ field, encrypted_names.include?(field.to_s) ? "[REDACTED]" : change ]
      end
    end
  end
end
