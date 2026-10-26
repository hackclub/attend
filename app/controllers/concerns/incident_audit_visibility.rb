# Audit rows about incidents have to honor Incident#visible_to_roles wherever
# they are listed, not only on the audit log itself: the event dashboard's
# activity feed reads the same table, and a row reading "Create Incident" still
# discloses that a hidden incident exists, who filed it and when.
#
# A reporter who holds none of an incident's roles gets the same receipt here
# as on the incident page (IncidentPolicy#view_casework?): the row for what
# they filed, but not the comments, edits and escalation that followed it.
module IncidentAuditVisibility
  extend ActiveSupport::Concern

  # Record types whose audit trail must honor Incident#visible_to_roles.
  INCIDENT_RECORD_TYPES = %w[Incident IncidentComment].freeze

  private

  def exclude_hidden_incident_logs(scope)
    scope.where.not(record_type: INCIDENT_RECORD_TYPES)
      .or(scope.where(record_type: "Incident", record_id: casework_incident_ids))
      .or(scope.where(record_type: "Incident", action: "record_create", record_id: visible_incident_ids))
      .or(scope.where(record_type: "IncidentComment",
        record_id: IncidentComment.where(incident_id: casework_incident_ids).select(:id)))
  end

  # Incidents (across the user's events) whose visible_to_roles intersects
  # the user's roles for that event, or that the user reported — the same
  # rule IncidentPolicy#show? enforces, but computed for all events since
  # audit logs span events.
  def visible_incident_ids
    @visible_incident_ids ||= incident_ids_by_event { |incidents, roles| incidents.visible_to_staff(current_user, roles) }
  end

  # The subset whose casework the user may read: shared with one of their
  # roles, whoever reported it — IncidentPolicy#view_casework?.
  def casework_incident_ids
    @casework_incident_ids ||= incident_ids_by_event { |incidents, roles| incidents.for_roles(roles) }
  end

  def incident_ids_by_event
    incident_roles_by_event
      .map { |event_id, roles| yield Incident.where(event_id: event_id), roles }
      .reduce(:or)
      &.pluck(:id) || []
  end

  def incident_roles_by_event
    @incident_roles_by_event ||= current_user.event_role_assignments
      .pluck(:event_id, :role)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }
  end
end
