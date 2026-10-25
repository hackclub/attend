module Admin
  class IncidentsController < BaseController
    before_action :require_event_selected
    before_action :set_incident, only: [ :show, :edit, :update, :escalate ]

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

      # Validate both halves up front so the organizer sees every problem at
      # once, and a failed escalation never leaves a half-done log entry.
      if escalation
        incident_ok = @incident.valid?
        escalation_ok = escalation.valid?
        unless incident_ok && escalation_ok
          escalation.errors.full_messages.each { |m| @incident.errors.add(:base, "Escalation: #{m}") }
          return render :new, status: :unprocessable_entity
        end
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

    # Escalates an existing log entry to HQ. Idempotent: a second POST, even a
    # concurrent one, lands back on the already-escalated incident. The row
    # lock serialises two organizers clicking at once; the unique index on
    # incident_reports.incident_id is the backstop.
    def escalate
      authorize @incident
      @record = @incident

      report = nil
      already = false
      @incident.with_lock do
        if @incident.escalated?
          already = true
        else
          report = build_escalation.call
        end
      end

      if already
        redirect_to admin_event_incident_path(current_event, @incident), notice: "This incident has already been escalated to Hack Club HQ."
      elsif report.persisted?
        notify_firehouse if firehouse_eligible?
        redirect_to admin_event_incident_path(current_event, @incident), notice: "Escalated to Hack Club HQ. Their safeguarding team has been notified."
      else
        redirect_to admin_event_incident_path(current_event, @incident), alert: "Couldn't escalate: #{report.errors.full_messages.to_sentence}"
      end
    rescue ActiveRecord::RecordNotUnique
      redirect_to admin_event_incident_path(current_event, @incident), notice: "This incident has already been escalated to Hack Club HQ."
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
        :medication_dispensed,
        visible_to_roles: [],
        medications_attributes: [ :id, :name, :dose, :notes, :_destroy ],
        participant_event_ids: [],
        helping_staff_ids: []
      )
    end

    def escalate_requested?
      params[:escalate] == "1"
    end

    def escalation_params
      params.fetch(:escalation, {}).permit(:emergency_services_called, :reporter_phone)
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
