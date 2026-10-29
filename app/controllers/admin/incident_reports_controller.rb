module Admin
  # The HQ incidents page at /admin/incidents. Two kinds of record live here:
  # reports to HQ (the public /incident form plus organizer escalations) and
  # every event's incident log. Global admins only.
  class IncidentReportsController < BaseController
    global_page
    VIEWS = %w[all reports logs].freeze
    # The inbox is a triage view, not an archive: show the newest rows and
    # say when there are more, rather than decrypting every summary ever.
    LIMIT = 200

    def index
      authorize IncidentReport

      @view = VIEWS.include?(params[:view]) ? params[:view] : "all"
      # Triage view: resolved reports and closed log entries stay out of the
      # way until the "Show resolved" toggle is on.
      @show_resolved = params[:resolved] == "1"

      reports = policy_scope(IncidentReport).includes(:event, :user, incident: :event).order(created_at: :desc)
      reports = reports.where(priority: params[:priority]) if IncidentLevel::KEYS.include?(params[:priority])
      @hidden_resolved_count = @show_resolved ? 0 : reports.where(status: "resolved").count
      reports = reports.where.not(status: "resolved") unless @show_resolved
      @incident_reports = reports.limit(LIMIT + 1).to_a
      @reports_truncated = @incident_reports.size > LIMIT
      @incident_reports = @incident_reports.first(LIMIT)
      @reports_by_status = @incident_reports.group_by(&:status)

      logs = Incident.includes(:event, :reported_by, :hq_report).order(created_at: :desc)
      logs = logs.where(event_id: params[:event_id]) if params[:event_id].present?
      @hidden_closed_count = @show_resolved ? 0 : logs.closed.count
      logs = logs.open_incidents unless @show_resolved
      @incidents = logs.limit(LIMIT + 1).to_a
      @incidents_truncated = @incidents.size > LIMIT
      @incidents = @incidents.first(LIMIT)
      @log_events = Event.where(id: Incident.select(:event_id)).order(starts_at: :desc)
    end

    def show
      @incident_report = IncidentReport.includes(:event, :user, incident: :event, comments: :user).find(params[:id])
      authorize @incident_report
    end
  end
end
