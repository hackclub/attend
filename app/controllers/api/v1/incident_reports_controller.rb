module Api
  module V1
    # The public confidential report form (/incident) for the mobile app. A
    # bearer token is a signed-in person, so there is no Turnstile challenge
    # and the report is linked to their account, as on the web when signed in.
    class IncidentReportsController < BaseController
      before_action :reject_api_key_auth

      # What the form offers, prefilled from the account the way the web form
      # prefills a signed-in reporter.
      def options
        render json: {
          roles: IncidentReport::ROLES.map { |value, label| { value: value, label: label } },
          incident_types: IncidentReport::INCIDENT_TYPES.map { |value, label| { value: value, label: label } },
          levels: IncidentLevel::LEVELS.map do |level|
            { value: level.key, code: level.code, name: level.name, target: level.target, label: level.label, color: level.color, examples: level.examples }
          end,
          emergency_level: IncidentLevel::EMERGENCY,
          default_level: IncidentLevel::DEFAULT,
          events: reportable_events.map do |event|
            { value: event.id, label: event.name, emergency_allowed: event.ends_at.nil? || event.ends_at >= IncidentReport::EMERGENCY_EVENT_WINDOW.ago }
          end,
          custom_events: Setting.incident_reports_custom_event_list.map do |name|
            { value: "custom:#{name}", label: name, emergency_allowed: false }
          end,
          organizer_events: organizer_events.map { |event| { id: event.id, name: event.name } },
          max_attachment_count: IncidentReport::MAX_ATTACHMENT_COUNT,
          max_attachment_bytes: IncidentReport::MAX_ATTACHMENT_BYTE_SIZE,
          prefill: {
            reporter_name: current_user.display_name_or_fallback,
            reporter_email: current_user.email,
            reporter_phone: current_user.oidc_claims&.dig("phone_number")
          }
        }
      end

      def create
        report = IncidentReport.new(incident_report_params)
        assign_event_choice(report, params[:event_choice])
        report.user = current_user

        if report.save
          report.dispatch_notifications!
          render json: { incident_report: { id: report.id, priority: report.priority, created_at: report.created_at.iso8601 } },
            status: :created
        else
          render json: { error: report.errors.full_messages.to_sentence, errors: report.errors.full_messages },
            status: :unprocessable_entity
        end
      end

      private

      def reject_api_key_auth
        return unless api_key_request?

        render json: { error: "API key is not authorized for incident reports" }, status: :forbidden
      end

      # Multipart from the app nests fields as incident_report[...], the same
      # shape the web form posts.
      def incident_report_params
        params.require(:incident_report).permit(
          :reporter_name,
          :reporter_email,
          :reporter_phone,
          :reporter_role,
          :incident_type,
          :emergency_services_called,
          :priority,
          :summary,
          :details,
          attachments: []
        )
      end

      # Mirrors IncidentReportsController: running events plus those that
      # finished within the last six months.
      def reportable_events
        Event
          .where("starts_at <= ?", Time.current)
          .where("ends_at >= ?", 6.months.ago)
          .order(starts_at: :desc)
      end

      # Events the reporter helps run, so the app can point them at the
      # event's incident log, which can escalate to HQ from there.
      def organizer_events
        reportable_events.where(id: current_user.event_role_assignments.select(:event_id)).limit(3)
      end

      # "custom:<name>" for a listed past event that isn't on Attend. An id is
      # looked up among the events the form offers, so one that isn't there
      # fails "Please choose an event" instead of a foreign key.
      def assign_event_choice(report, choice)
        return if choice.blank?

        if choice.start_with?("custom:")
          report.custom_event_name = choice.delete_prefix("custom:")
        else
          report.event = reportable_events.find_by(id: choice)
        end
      end
    end
  end
end
