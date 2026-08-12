module Admin
  class EmailLogsController < Admin::BaseController
    before_action :require_global_admin

    def index
      @email_logs = EmailLog.includes(:event, :emailable).recent

      @email_logs = @email_logs.where(status: params[:status]) if params[:status].present?
      @email_logs = @email_logs.where("to_address ILIKE ?", "%#{params[:search]}%") if params[:search].present?

      @email_logs = @email_logs.limit(100)
    end

    def show
      @email_log = EmailLog.includes(:email_log_events).find(params[:id])
      @events = @email_log.email_log_events.chronological
    end

    private

    def require_global_admin
      unless current_user.global_admin?
        redirect_to admin_root_path, alert: "Access denied"
      end
    end
  end
end
