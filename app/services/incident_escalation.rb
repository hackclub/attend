# Turns an event incident into a confidential report to HQ.
#
# The organizer keeps their incident log entry; HQ gets an IncidentReport
# linked back to it, with the same notifications a public /incident submission
# triggers (email, Slack, confirmation text, emergency calls). Escalating twice
# is a no-op that returns the existing report.
class IncidentEscalation
  CATEGORY_TO_INCIDENT_TYPE = {
    "medical" => "medical_emergency",
    "safeguarding" => "event_safety",
    "behavior" => "event_safety",
    "other" => "other"
  }.freeze

  attr_reader :incident, :user

  def initialize(incident:, user:, priority: "standard", emergency_services_called: false, reporter_phone: nil)
    @incident = incident
    @user = user
    @priority = priority.presence || "standard"
    @emergency_services_called = ActiveModel::Type::Boolean.new.cast(emergency_services_called) || false
    @reporter_phone = reporter_phone.presence
  end

  def report
    @report ||= existing_report || build_report
  end

  # Checks the report without saving it, so a form can show HQ-side errors
  # (a missing callback number, say) before the incident is created.
  def valid?
    report.persisted? || report.valid?
  end

  def errors
    report.errors
  end

  def call
    return report if report.persisted?

    report.incident = incident
    if report.save
      incident.association(:hq_report).target = report
      report.dispatch_notifications!
    end
    report
  end

  private

  # The incident may have been loaded before an earlier escalation, so ask the
  # database rather than the association cache.
  def existing_report
    return unless incident.persisted?

    IncidentReport.find_by(incident_id: incident.id)
  end

  def build_report
    IncidentReport.new(
      incident: incident,
      event: incident.event,
      user: user,
      reporter_name: user.display_name_or_fallback,
      reporter_email: user.email,
      reporter_phone: @reporter_phone || user_phone,
      reporter_role: user.global_admin? ? "hq_employee" : "event_point_of_contact",
      incident_type: CATEGORY_TO_INCIDENT_TYPE.fetch(incident.category.to_s, "other"),
      priority: @priority,
      emergency_services_called: @emergency_services_called,
      summary: incident.summary.presence || "#{incident.category.to_s.humanize} incident at #{incident.event.name}",
      details: details
    )
  end

  def user_phone
    user.oidc_claims&.dig("phone_number").presence
  end

  def details
    parts = [ incident.details.presence || "(no details recorded)" ]
    parts << "Location: #{incident.location}" if incident.location.present?
    parts << "Occurred at: #{incident.occurred_at.strftime('%Y-%m-%d %H:%M %Z')}" if incident.occurred_at.present?
    parts << "Actions taken so far:\n#{incident.actions_taken}" if incident.actions_taken.present?
    parts << "Severity logged by the organizer: #{incident.severity}"
    parts.join("\n\n")
  end
end
