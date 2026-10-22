module Admin
  class IncidentsController < BaseController
    before_action :require_event_selected
    before_action :set_incident, only: [ :show, :edit, :update, :send_to_slack, :escalate ]

    def index
      @incidents = policy_scope(current_event.incidents).includes(:reported_by, :participants, :hq_report).order(created_at: :desc)
    end

    def show
      authorize @incident
    end

    def new
      @incident = current_event.incidents.build(visible_to_roles: Incident::DEFAULT_VISIBLE_TO_ROLES)
      authorize @incident
    end

    def create
      @incident = current_event.incidents.build(incident_params)
      @incident.reported_by = current_user
      authorize @incident

      escalation = build_escalation if escalate_requested?

      # Check HQ-side requirements (a callback number, mostly) before the
      # incident exists, so a failed escalation never leaves a half-done log entry.
      if escalation && !escalation.valid?
        escalation.errors.full_messages.each { |m| @incident.errors.add(:base, "Escalation: #{m}") }
        return render :new, status: :unprocessable_entity
      end

      if @incident.save
        if escalation
          report = escalation.call
          notify_firehouse if report.persisted? && firehouse_eligible?
        end
        redirect_to admin_event_incident_path(current_event, @incident), notice: create_notice(escalation)
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

    # Escalates an existing log entry to HQ. Idempotent: a second POST just
    # lands back on the already-escalated incident.
    def escalate
      authorize @incident

      if @incident.escalated?
        return redirect_to admin_event_incident_path(current_event, @incident), notice: "This incident has already been escalated to Hack Club HQ."
      end

      escalation = build_escalation
      report = escalation.call

      if report.persisted?
        @record = @incident
        notify_firehouse if firehouse_eligible?
        redirect_to admin_event_incident_path(current_event, @incident), notice: "Escalated to Hack Club HQ. Their safeguarding team has been notified."
      else
        redirect_to admin_event_incident_path(current_event, @incident), alert: "Couldn't escalate: #{report.errors.full_messages.to_sentence}"
      end
    end

    def send_to_slack
      authorize @incident

      unless firehouse_eligible?
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

    def escalate_requested?
      params[:escalate] == "1"
    end

    def escalation_params
      params.fetch(:escalation, {}).permit(:priority, :emergency_services_called, :reporter_phone)
    end

    def build_escalation
      IncidentEscalation.new(incident: @incident, user: current_user, **escalation_params.to_h.symbolize_keys)
    end

    # Medical incidents stay HQ-only; the Firehouse channel is for conduct.
    def firehouse_eligible?
      @incident.behavior? || @incident.safeguarding? || @incident.other?
    end

    def notify_firehouse
      SendIncidentToSlackJob.perform_later(@incident.id, current_user.id)
    end

    def create_notice(escalation)
      if escalation&.report&.persisted?
        "Incident logged and escalated to Hack Club HQ."
      elsif escalation
        "Incident logged, but the HQ report couldn't be filed. You can retry from the incident page."
      else
        "Incident was successfully created."
      end
    end
  end
end
