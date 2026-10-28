module Api
  module V1
    # Comments on an event incident, as Admin::IncidentCommentsController.
    class IncidentCommentsController < BaseController
      include Pundit::Authorization
      include Api::V1::ApiAuditing

      rescue_from Pundit::NotAuthorizedError do
        render json: { error: "Forbidden" }, status: :forbidden
      end

      before_action :reject_api_key_auth
      before_action :set_paper_trail_whodunnit
      before_action :set_incident

      def create
        authorize @incident, :comment?
        comment = @incident.comments.build(comment_params)
        comment.user = current_user

        # The status is applied with update!, which an unknown value would
        # turn into a 500 after the comment had already been written.
        if comment.new_status.present? && !Incident.statuses.key?(comment.new_status)
          return render json: { error: "Unknown status #{comment.new_status}" }, status: :unprocessable_entity
        end

        if comment.save
          audit_api_change!(:record_create, comment)
          SendIncidentCommentToSlackJob.perform_later(comment.id) if @incident.slack_message_ts.present?
          render json: {
            comment: { id: comment.id, body: comment.body, new_status: comment.new_status.presence, created_at: comment.created_at.iso8601 },
            incident_status: @incident.reload.status
          }, status: :created
        else
          render json: { error: comment.errors.full_messages.to_sentence, errors: comment.errors.full_messages },
            status: :unprocessable_entity
        end
      end

      private

      def reject_api_key_auth
        return unless api_key_request?

        render json: { error: "API key is not authorized for incidents" }, status: :forbidden
      end

      def set_paper_trail_whodunnit
        PaperTrail.request.whodunnit = current_user&.id
      end

      def set_incident
        @event = Event.find_by(id: params[:event_id]) || Event.find_by!(slug: params[:event_id])
        Current.event = @event
        @incident = @event.incidents.find(params[:incident_id])
      end

      # A status picked with a comment is an update, so it answers to the same
      # rule as the edit form; a reporter's comment drops it.
      def comment_params
        permitted = params.require(:comment).permit(:body, :new_status)
        policy(@incident).update? ? permitted : permitted.except(:new_status)
      end
    end
  end
end
