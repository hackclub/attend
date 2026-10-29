module Admin
  class IncidentReportCommentsController < BaseController
    global_page
    before_action :set_incident_report

    def create
      authorize @incident_report, :comment?
      @comment = @incident_report.comments.build(comment_params)
      @comment.user = current_user

      if @comment.save
        if @comment.new_status.present? && @incident_report.slack_message_ts.present?
          SendIncidentReportToSlackJob.perform_later(@incident_report.id)
        end
        SendIncidentReportCommentToSlackJob.perform_later(@comment.id) if @incident_report.slack_message_ts.present?

        if params[:share_with_reporter].present? && @incident_report.reporter_phone.present?
          SendIncidentReportUpdateSmsJob.perform_later(@comment.id)
        end

        redirect_to admin_incident_report_path(@incident_report), notice: notice_message
      elsif request.variant.include?(:console)
        # The console re-renders the report with the comment's errors under
        # its fields; the original UI keeps its redirect.
        @incident_report.comments.reset
        render "admin/incident_reports/show", status: :unprocessable_entity
      else
        redirect_to admin_incident_report_path(@incident_report), alert: "Failed to add comment."
      end
    end

    private

    def notice_message
      if params[:share_with_reporter].present? && @incident_report.reporter_phone.present?
        "Comment added and texted to the reporter."
      else
        "Comment added."
      end
    end

    def set_incident_report
      @incident_report = IncidentReport.find(params[:incident_id])
    end

    def comment_params
      params.require(:incident_report_comment).permit(:body, :new_status, attachments: [])
    end
  end
end
