module Admin
  class IncidentsController < BaseController
    before_action :require_event_selected
    before_action :set_incident, only: [ :show, :edit, :update, :send_to_slack ]

    def index
      @incidents = policy_scope(current_event.incidents).includes(:reported_by, :participants).order(created_at: :desc)
    end

    def show
      authorize @incident
    end

    def new
      @incident = current_event.incidents.build
      authorize @incident
    end

    def create
      @incident = current_event.incidents.build(incident_params)
      @incident.reported_by = current_user
      authorize @incident

      if @incident.save
        if params[:sync_to_slack] == "1"
          SendIncidentToSlackJob.perform_later(@incident.id, current_user.id)
        end
        redirect_to admin_event_incident_path(current_event, @incident), notice: "Incident was successfully created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @incident
    end

    def update
      authorize @incident

      changes = nil
      if @incident.slack_message_ts.present?
        @incident.assign_attributes(incident_params)
        changes = @incident.changes.except("updated_at")
      end

      if @incident.update(incident_params)
        if changes.present? && changes.any?
          SendIncidentUpdateToSlackJob.perform_later(@incident.id, current_user.id, changes)
        end
        redirect_to admin_event_incident_path(current_event, @incident), notice: "Incident was successfully updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def send_to_slack
      authorize @incident

      unless @incident.behavior? || @incident.safeguarding? || @incident.other?
        redirect_to admin_event_incident_path(current_event, @incident), alert: "Medical incidents cannot be sent to Slack."
        return
      end

      SendIncidentToSlackJob.perform_later(@incident.id, current_user.id)
      redirect_to admin_event_incident_path(current_event, @incident), notice: "Conduct report is being sent to Slack."
    end

    private

    def set_incident
      @incident = current_event.incidents.find(params[:id])
    end

    def incident_params
      params.require(:incident).permit(
        :category,
        :severity,
        :status,
        :summary,
        :details,
        :actions_taken,
        :location,
        :occurred_at,
        visible_to_roles: [],
        participant_event_ids: [],
        helping_staff_ids: []
      )
    end
  end
end
