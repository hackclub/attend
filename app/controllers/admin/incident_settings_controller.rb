module Admin
  class IncidentSettingsController < BaseController
    before_action :require_global_admin

    def show
      load_settings
    end

    def update
      Setting.incident_reports_slack_channel_id = params[:incident_reports_slack_channel_id]
      Setting.incident_reports_responder_user_ids = params[:responder_user_ids]
      Setting.incident_reports_custom_events = params[:incident_reports_custom_events]

      redirect_to admin_incident_settings_path, notice: "Incident report settings updated."
    end

    private

    def load_settings
      @slack_channel_id = Setting.incident_reports_slack_channel_id
      @effective_channel_id = SendIncidentReportToSlackJob.channel_id
      @selectable_users = User.where(global_role: "global_admin").order(:name)
      @selected_user_ids = Setting.incident_reports_responder_user_id_list
      @responders = Setting.incident_responders
      @custom_events = Setting.incident_reports_custom_events
    end

    def require_global_admin
      unless current_user&.global_admin?
        redirect_to admin_root_path, alert: "You must be a global admin to access incident settings."
      end
    end
  end
end
