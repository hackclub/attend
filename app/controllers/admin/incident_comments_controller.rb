module Admin
  class IncidentCommentsController < BaseController
    before_action :require_event_selected
    before_action :set_incident

    def create
      @comment = @incident.comments.build(comment_params)
      @comment.user = current_user
      authorize @incident, :comment?

      if @comment.save
        SendIncidentCommentToSlackJob.perform_later(@comment.id) if @incident.slack_message_ts.present?
        redirect_to admin_event_incident_path(current_event, @incident), notice: "Comment added."
      elsif request.variant.include?(:console)
        # The console re-renders the incident with the comment's errors under
        # its fields; the original UI keeps its redirect.
        @incident.comments.reset
        render "admin/incidents/show", status: :unprocessable_entity
      else
        redirect_to admin_event_incident_path(current_event, @incident), alert: "Failed to add comment."
      end
    end

    private

    def set_incident
      @incident = current_event.incidents.find(params[:incident_id])
    end

    def comment_params
      params.require(:incident_comment).permit(:body, :new_status)
    end
  end
end
