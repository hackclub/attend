module Api
  module V1
    # The event incident log for the mobile app: the same records, rules and
    # side effects as Admin::IncidentsController, as JSON. Access is
    # IncidentPolicy's, which reads the event from Current.event.
    class IncidentsController < BaseController
      include Pundit::Authorization
      include Api::V1::ApiAuditing

      rescue_from Pundit::NotAuthorizedError do
        render json: { error: "Forbidden" }, status: :forbidden
      end

      before_action :reject_api_key_auth
      before_action :set_paper_trail_whodunnit
      before_action :set_event
      before_action :set_incident, only: [ :show, :update, :escalate ]

      def index
        authorize Incident
        incidents = policy_scope(@event.incidents)
          .includes(:reported_by, :participants, :hq_report)
          .order(created_at: :desc)

        render json: { incidents: incidents.map { |incident| incident_summary_json(incident) } }
      end

      # What the new and edit forms offer: the scale, the pick lists, and the
      # people on this event an incident can name.
      def options
        authorize Incident, :create?

        render json: {
          categories: Incident.categories.keys.map { |c| { value: c, label: c.humanize } },
          levels: IncidentLevel::LEVELS.map { |level| level_json(level) },
          statuses: Incident.statuses.keys.map { |s| { value: s, label: s.humanize } },
          roles: EventRoleAssignment.roles.keys.map { |r| { value: r, label: r.humanize } },
          default_visible_to_roles: Incident::DEFAULT_VISIBLE_TO_ROLES,
          default_severity: IncidentLevel::DEFAULT,
          emergency_level: IncidentLevel::EMERGENCY,
          participants: @event.participant_events.includes(:participant).order("participants.legal_first_name").map do |pe|
            { id: pe.id, name: pe.participant.display_name, email: pe.participant.email }
          end,
          staff: @event.event_role_assignments.includes(:user).map(&:user).uniq.sort_by(&:display_name_or_fallback).map do |user|
            { id: user.id, name: user.display_name_or_fallback, email: user.email }
          end,
          reporter_phone: current_user.oidc_claims&.dig("phone_number")
        }
      end

      def show
        authorize @incident
        render json: { incident: incident_json(@incident) }
      end

      def create
        incident = @event.incidents.build(incident_params)
        incident.reported_by = current_user
        authorize incident

        escalation = build_escalation(incident) if params[:escalate].present? && ActiveModel::Type::Boolean.new.cast(params[:escalate])

        # Both halves are checked before anything is saved, as on the web form,
        # so a failed escalation never leaves a half-done log entry.
        if escalation
          incident_ok = incident.valid?
          escalation_ok = escalation.valid?
          unless incident_ok && escalation_ok
            escalation.errors.full_messages.each { |m| incident.errors.add(:base, "Escalation: #{m}") }
            return render_validation_errors(incident)
          end
        end

        return render_validation_errors(incident) unless incident.save

        audit_api_change!(:record_create, incident)
        escalated = false
        if escalation
          report = escalation.call
          escalated = report.persisted?
          notify_firehouse(incident) if escalated && firehouse_eligible?(incident)
        end

        render json: {
          incident: incident_json(incident.reload),
          notice: create_notice(escalation, escalated)
        }, status: :created
      end

      def update
        authorize @incident

        @incident.assign_attributes(incident_params)
        changes = @incident.changes.except("updated_at")
        return render_validation_errors(@incident) unless @incident.save

        audit_api_change!(:record_update, @incident)
        if @incident.slack_message_ts.present? && changes.any?
          SendIncidentUpdateToSlackJob.perform_later(@incident.id, current_user.id, changes)
        end

        render json: { incident: incident_json(@incident.reload), notice: "Incident was successfully updated." }
      end

      # Idempotent like the web action: the row lock serialises two people
      # escalating at once, and the unique index is the backstop.
      def escalate
        authorize @incident

        report = nil
        already = false
        @incident.with_lock do
          if @incident.escalated?
            already = true
          else
            report = build_escalation(@incident).call
          end
        end

        if already
          render json: { incident: incident_json(@incident.reload), notice: "This incident has already been escalated to Hack Club HQ." }
        elsif report.persisted?
          audit_api_change!(:escalate, @incident, changed_fields: {}, metadata: { incident_report_id: report.id })
          notify_firehouse(@incident) if firehouse_eligible?(@incident)
          render json: { incident: incident_json(@incident.reload), notice: "Escalated to Hack Club HQ. Their safeguarding team has been notified." }
        else
          render json: { error: "Couldn't escalate: #{report.errors.full_messages.to_sentence}", errors: report.errors.full_messages },
            status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotUnique
        render json: { incident: incident_json(@incident.reload), notice: "This incident has already been escalated to Hack Club HQ." }
      end

      private

      # Incidents are attributed to the person who logs them.
      def reject_api_key_auth
        return unless api_key_request?

        render json: { error: "API key is not authorized for incidents" }, status: :forbidden
      end

      def set_paper_trail_whodunnit
        PaperTrail.request.whodunnit = current_user&.id
      end

      def set_event
        @event = Event.find_by(id: params[:event_id]) || Event.find_by!(slug: params[:event_id])
        Current.event = @event
      end

      def set_incident
        @incident = @event.incidents.find(params[:id])
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

      def escalation_params
        params.fetch(:escalation, {}).permit(:emergency_services_called, :reporter_phone)
      end

      def build_escalation(incident)
        IncidentEscalation.new(incident: incident, user: current_user, **escalation_params.to_h.symbolize_keys)
      end

      # Medical incidents stay HQ-only; the Firehouse channel is for conduct.
      def firehouse_eligible?(incident)
        incident.behavior? || incident.safeguarding? || incident.other?
      end

      def notify_firehouse(incident)
        SendIncidentToSlackJob.perform_later(incident.id, current_user.id)
      end

      def create_notice(escalation, escalated)
        if escalated
          "Incident logged and escalated to Hack Club HQ."
        elsif escalation
          "Incident logged, but the HQ report couldn't be filed. You can retry from the incident page."
        else
          "Incident was successfully created."
        end
      end

      def render_validation_errors(record)
        render json: { error: record.errors.full_messages.to_sentence, errors: record.errors.full_messages },
          status: :unprocessable_entity
      end

      def level_json(level)
        {
          value: level.key,
          code: level.code,
          name: level.name,
          target: level.target,
          label: level.label,
          color: level.color,
          examples: level.examples
        }
      end

      def person_json(user)
        return nil unless user

        { id: user.id, name: user.display_name_or_fallback, email: user.email }
      end

      def hq_report_json(report)
        return nil unless report

        { id: report.id, status: report.status, created_at: report.created_at.iso8601 }
      end

      def incident_summary_json(incident)
        {
          id: incident.id,
          category: incident.category,
          severity: incident.severity,
          status: incident.status,
          summary: incident.summary,
          location: incident.location,
          occurred_at: incident.occurred_at&.iso8601,
          created_at: incident.created_at.iso8601,
          reported_by: person_json(incident.reported_by),
          participant_names: incident.participants.map { |p| p.preferred_name || p.legal_first_name },
          hq_report: hq_report_json(incident.hq_report)
        }
      end

      def incident_json(incident)
        policy = policy(incident)
        casework = policy.view_casework?
        participant_events = incident.incident_participants.includes(participant_event: :participant).map(&:participant_event)

        incident_summary_json(incident).merge(
          details: incident.details,
          actions_taken: casework ? incident.actions_taken : nil,
          visible_to_roles: incident.visible_to_roles.reject(&:blank?),
          medication_dispensed: incident.medication_dispensed?,
          medications: incident.medications.map { |m| { id: m.id, name: m.name, dose: m.dose, notes: m.notes } },
          participants: participant_events.map do |pe|
            participant = pe.participant
            {
              id: pe.id,
              name: "#{participant.preferred_name || participant.legal_first_name} #{participant.legal_last_name}",
              email: participant.email
            }
          end,
          helping_staff: incident.helping_staff.map { |user| person_json(user) },
          timeline: casework ? timeline_json(incident) : [],
          permissions: {
            update: policy.update?,
            comment: policy.comment?,
            # Changing status from the comment box is an update.
            change_status: policy.update?,
            view_casework: casework,
            escalate: policy.escalate? && !incident.escalated?
          }
        )
      end

      # The casework timeline the web show page renders: every comment, plus
      # each version except the update a status-changing comment caused.
      def timeline_json(incident)
        comments = incident.comments.includes(:user).to_a
        status_change_times = comments.select { |c| c.new_status.present? }.map { |c| c.created_at.to_i }
        versions = incident.versions.reject { |v| v.event == "update" && status_change_times.include?(v.created_at.to_i) }
        actors = User.where(id: versions.map(&:whodunnit).compact.uniq).index_by { |u| u.id.to_s }

        items = comments.map { |c| [ c.created_at, comment_json(c) ] }
        items += versions.map do |version|
          actor = actors[version.whodunnit.to_s]
          [ version.created_at, {
            type: "change",
            id: version.id.to_s,
            action: version.event == "create" ? "created" : "updated",
            actor_name: actor&.display_name_or_fallback || "System",
            fields: (version.changeset || {}).keys.reject { |k| k == "updated_at" }.map(&:humanize),
            created_at: version.created_at.iso8601
          } ]
        end
        items.sort_by(&:first).reverse.map(&:last)
      end

      def comment_json(comment)
        from_slack = comment.source == "slack"
        {
          type: "comment",
          id: comment.id,
          body: comment.body,
          new_status: comment.new_status.presence,
          author_name: from_slack ? "Fire Dept (#{comment.slack_display_name.presence || comment.slack_user_id})" : comment.user&.display_name_or_fallback,
          source: comment.source,
          slack_url: from_slack ? "https://hackclub.slack.com/archives/#{comment.slack_channel_id}/p#{comment.slack_message_ts&.delete('.')}" : nil,
          created_at: comment.created_at.iso8601
        }
      end
    end
  end
end
