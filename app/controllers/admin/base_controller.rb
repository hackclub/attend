module Admin
  class BaseController < ApplicationController
    before_action :authenticate_user!
    before_action :set_admin_ui_variant
    before_action :authorize_admin_access
    before_action :set_current_event_from_session
    before_action :switch_event_if_needed
    before_action :ensure_can_access_current_event, if: -> { current_event.present? }
    before_action :ensure_can_change_current_event, if: :event_write_request?
    after_action :log_admin_action, unless: -> { request.get? }

    layout "admin"

    helper_method :current_event, :available_events, :switcher_events, :can_view_participant_pii?,
      :registration_change_request_pending_count, :event_page?,
      :show_waiver_dates_banner?

    class_attribute :global_page_actions, instance_writer: false, default: [].freeze

    # Declares the pages that aren't about any one event (users, bans, the visa
    # letter templates), or with `only:` just those actions. The event picked
    # in the session stays folded away in the side nav, one click away, but
    # its banners (no arrival window, stale waiver dates, training needed)
    # stay off these pages and nothing done on them is audit-logged against it.
    def self.global_page(only: :all)
      self.global_page_actions = only == :all ? :all : Array(only).map(&:to_s).freeze
    end

    def event_page?
      return false unless current_event

      global_page_actions != :all && !global_page_actions.include?(action_name)
    end

    # The stale-waiver-dates banner links to the regeneration flow, so the
    # controller that is that flow turns it off.
    def show_waiver_dates_banner?
      event_page? && current_event.waiver_dates_stale?
    end

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

    # What the console's event switcher lists: running and upcoming events,
    # plus the current one. Long-finished events are dropped in SQL — with
    # every event a global admin can see, loading them all was most of the
    # layout's cost on every page. Two days of slack covers any time zone, and
    # the switcher still asks Event#completed? about what's left.
    def switcher_events
      @switcher_events ||= begin
        recent = available_events.where(ends_at: nil).or(available_events.where(ends_at: 2.days.ago..))
        recent = recent.or(available_events.where(id: current_event.id)) if current_event
        recent.to_a
      end
    end

    def registration_change_request_pending_count
      return 0 unless current_event

      @registration_change_request_pending_count ||= policy_scope(RegistrationChangeRequest).pending.count
    end

    private

    # Every admin page renders the console (Cloudscape) UI. The +console
    # variant marks templates and partials as admin renders: shared partials
    # that also appear outside /admin keep a plain *.html.erb for those pages,
    # and helpers branch on ConsoleHelper#console_ui?. Set before any action
    # runs so renders, Turbo Stream responses and render_to_string all see it.
    # The lookup context is set too: turbo_stream.replace(partial: ...) renders
    # its partial when the stream is built, before `render` would copy the
    # request variant across, so it would otherwise miss the +console partials.
    def set_admin_ui_variant
      request.variant = :console
      lookup_context.variants = [ :console ]
    end

    def authorize_admin_access
      return if current_user&.admin?

      # Someone partway through an event creation invite has one admin page
      # open to them, the new event form; send them back to it.
      if (invite = EventCreationInvite.usable_by(current_user).first)
        redirect_to admin_new_event_path(invite: invite.id)
      else
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
        redirect_to admin_root_path, alert: "Please select an event first."
      end
    end

    def can_access_current_event?
      return true if current_user.global_admin?
      return false unless current_event

      current_user.can_access_event?(current_event)
    end

    # A write to an event-scoped route. Getting into /admin only takes an
    # admin role on some event, so someone who is ops on one event and
    # read_only on another reaches both; this is what keeps the read_only one
    # read-only, whatever the individual controller checks.
    def event_write_request?
      current_event.present? && params[:event_slug].present? && !request.get? && !request.head?
    end

    def ensure_can_change_current_event
      raise Pundit::NotAuthorizedError unless current_user.can_change_event?(current_event)
    end

    def ensure_can_access_current_event
      return if can_access_current_event?

      session[:current_event_id] = nil
      Current.event = nil
      @current_event = nil

      redirect_to admin_root_path,
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

    # Who is acting, for app/operations. One per request: it remembers what
    # operations audited, and log_admin_action stands down when they have.
    def operation_context
      @operation_context ||= Operation::Context.new(
        surface: :html,
        user: current_user,
        event: (current_event if event_page?),
        metadata: admin_audit_metadata
      )
    end

    # What every audit row from the admin UI says about the request, whether
    # an operation writes the row or the catch-all hook does. The params are
    # as Rails filtered them; whoever writes the row redacts the registry's
    # PII from them for the record it is about (SensitiveFields.redact_params).
    def admin_audit_metadata
      {
        ip: request.remote_ip,
        user_agent: request.user_agent,
        controller: controller_name,
        params: request.filtered_parameters.except("controller", "action", "authenticity_token")
      }
    end

    # The catch-all: audits whatever record the action left changed, under the
    # action's own name. Actions that run an operation are audited by it, by
    # name, and are skipped here so there is one row, not two.
    def log_admin_action
      return unless current_user
      return if @operation_context&.audited?

      changed_record = find_changed_record
      record = changed_record || @record || @event || @participant_event
      # Skip audit logging for actions without a record (e.g., impersonation),
      # and for records that were never persisted — a create that failed
      # validation re-renders the form with an id-less object, which AuditLog
      # rejects. In development that rejection re-raises (see below) and
      # replaces the 422 form (errors and all) with an exception page that
      # Turbo full-reloads, so the admin just sees the form silently reset.
      return if record.nil? || record.id.blank?

      changed_fields = if changed_record
        changed_record.previous_changes.except("updated_at", "created_at")
      elsif record.respond_to?(:previous_changes)
        record.previous_changes.except("updated_at", "created_at")
      else
        {}
      end
      changed_fields = AuditLog.redact_sensitive_fields(record, changed_fields)

      event_for_log = current_event if event_page? && !current_event.destroyed?

      AuditLog.log!(
        action: action_name,
        record: record,
        actor: current_user,
        event: event_for_log,
        changed_fields: changed_fields,
        # filter_parameters doesn't name every PII column in the registry
        # (city, state, postal_code, country), and the request's params are
        # stored whether or not the action permitted them.
        metadata: admin_audit_metadata.tap { |metadata|
          metadata[:params] = SensitiveFields.redact_params(metadata[:params], model: record.class)
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
  end
end
