module Admin
  class IncidentReportsController < BaseController
    before_action :require_global_admin

    def index
      scope = IncidentReport.includes(:event, :user).order(created_at: :desc)
      scope = scope.where(priority: params[:priority]) if IncidentReport::PRIORITIES.key?(params[:priority])
      @incident_reports = scope
      @reports_by_status = @incident_reports.group_by(&:status)
    end

    def show
      @incident_report = IncidentReport.includes(:event, :user, comments: :user).find(params[:id])
    end

    private

    def require_global_admin
      unless current_user&.global_admin?
        redirect_to admin_root_path, alert: "You must be a global admin to view incident reports."
      end
    end
  end
end
