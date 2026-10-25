# Audit rows about incidents have to honor Incident#visible_to_roles wherever
# they are listed, not only on the audit log itself: the event dashboard's
# activity feed reads the same table, and a row reading "Create Incident" still
# discloses that a hidden incident exists, who filed it and when.
module IncidentAuditVisibility
  extend ActiveSupport::Concern

  # Record types whose audit trail must honor Incident#visible_to_roles.
  INCIDENT_RECORD_TYPES = %w[Incident IncidentComment].freeze

  private

  def exclude_hidden_incident_logs(scope)
    scope.where.not(record_type: INCIDENT_RECORD_TYPES)
      .or(scope.where(record_type: "Incident", record_id: visible_incident_ids))
      .or(scope.where(record_type: "IncidentComment",
        record_id: IncidentComment.where(incident_id: visible_incident_ids).select(:id)))
  end

  # Incidents (across the user's events) whose visible_to_roles intersects
  # the user's roles for that event, or that the user reported — the same
  # rule IncidentPolicy enforces, but computed for all events since audit
  # logs span events.
  def visible_incident_ids
    @visible_incident_ids ||= begin
      roles_by_event = current_user.event_role_assignments
        .pluck(:event_id, :role)
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last) }

      roles_by_event
        .map { |event_id, roles| Incident.where(event_id: event_id).visible_to_staff(current_user, roles) }
        .reduce(:or)
        &.pluck(:id) || []
    end
  end
end
