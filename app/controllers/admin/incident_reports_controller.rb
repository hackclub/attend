module Admin
  # The HQ incident inbox at /admin/incidents. Two kinds of record live here:
  # reports to HQ (the public /incident form plus organizer escalations) and
  # every event's incident log. Global admins only.
  class IncidentReportsController < BaseController
    VIEWS = %w[all reports logs].freeze

    def index
      authorize IncidentReport

      @view = VIEWS.include?(params[:view]) ? params[:view] : "all"

      reports = policy_scope(IncidentReport).includes(:event, :user, incident: :event).order(created_at: :desc)
      reports = reports.where(priority: params[:priority]) if IncidentReport::PRIORITIES.key?(params[:priority])
      @incident_reports = reports
      @reports_by_status = @incident_reports.group_by(&:status)

      logs = Incident.includes(:event, :reported_by, :hq_report).order(created_at: :desc)
      logs = logs.where(event_id: params[:event_id]) if params[:event_id].present?
      logs = logs.open_incidents if params[:open] == "1"
      @incidents = logs
      @log_events = Event.where(id: Incident.select(:event_id)).order(starts_at: :desc)
    end

    def show
      @incident_report = IncidentReport.includes(:event, :user, incident: :event, comments: :user).find(params[:id])
      authorize @incident_report
    end
  end
end
