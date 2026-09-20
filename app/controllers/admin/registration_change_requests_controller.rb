module Admin
  class RegistrationChangeRequestsController < BaseController
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

    before_action :require_event_selected
    before_action :load_change_request, except: :index

    def index
      @change_requests = policy_scope(RegistrationChangeRequest)
        .includes(participant_event: :participant)
        .pending_first
    end

    def show
      authorize @change_request
    end

    def approve
      authorize @change_request, :approve?
      result = RegistrationChangeRequests::Approve.call(request: @change_request, reviewer: current_user)
      notice = result == :approved ? "Change request approved." : "Request marked for staff follow-up."
      redirect_to admin_event_registration_change_request_path(current_event, @change_request), notice: notice
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      redirect_to admin_event_registration_change_request_path(current_event, @change_request), alert: e.message
    end

    def request_follow_up
      authorize @change_request, :request_follow_up?
      response = params.require(:registration_change_request).permit(:staff_response)[:staff_response]
      if response.blank?
        return redirect_to admin_event_registration_change_request_path(current_event, @change_request),
          alert: "Add a message explaining what is needed."
      end

      @change_request.with_lock do
        raise ArgumentError, "Request has already been resolved" unless @change_request.pending?

        @change_request.update!(status: :follow_up_needed, staff_response: response,
          resolved_by: current_user, resolved_at: Time.current)
      end
      RegistrationCorrectionMailer.participant_follow_up(change_request: @change_request).deliver_later
      redirect_to admin_event_registration_change_request_path(current_event, @change_request),
        notice: "Follow-up requested."
    rescue ArgumentError => e
      redirect_to admin_event_registration_change_request_path(current_event, @change_request), alert: e.message
    end

    private

    def render_not_found
      head :not_found
    end

    def load_change_request
      @change_request = policy_scope(RegistrationChangeRequest).find(params[:id])
    end
  end
end
