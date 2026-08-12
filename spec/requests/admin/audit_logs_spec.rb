require "rails_helper"

RSpec.describe "Admin::AuditLogs", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:global_admin) { User.create!(email: "ga-audit@example.com", name: "Global Admin", global_role: "global_admin") }
  let(:reporter) { User.create!(email: "reporter-audit@example.com", name: "Reporter") }
  let(:event_admin) do
    User.create!(email: "ea-audit@example.com", name: "Event Admin").tap do |user|
      EventRoleAssignment.create!(user: user, event: event, role: "event_admin")
    end
  end

  def create_incident(visible_to_roles:)
    Incident.create!(
      event: event,
      reported_by: reporter,
      category: "behavior",
      severity: "low",
      summary: "Confidential summary",
      details: "Confidential details",
      visible_to_roles: visible_to_roles
    )
  end

  def log_for(record)
    AuditLog.log!(action: "update", record: record, actor: reporter, event: event)
  end

  describe "GET show" do
    it "blocks an event admin from an incident hidden from their role" do
      incident = create_incident(visible_to_roles: [ "safeguarding_lead" ])
      log = log_for(incident)
      sign_in event_admin

      get admin_audit_log_path(log)

      expect(response).to redirect_to(admin_audit_logs_path)
    end

    it "blocks an event admin when no roles were selected (global admins only)" do
      incident = create_incident(visible_to_roles: [])
      log = log_for(incident)
      sign_in event_admin

      get admin_audit_log_path(log)

      expect(response).to redirect_to(admin_audit_logs_path)
    end

    it "blocks an event admin from comments on a hidden incident" do
      incident = create_incident(visible_to_roles: [])
      comment = IncidentComment.create!(incident: incident, user: reporter, body: "secret comment")
      log = log_for(comment)
      sign_in event_admin

      get admin_audit_log_path(log)

      expect(response).to redirect_to(admin_audit_logs_path)
    end

    it "allows an event admin when their role was selected" do
      incident = create_incident(visible_to_roles: [ "event_admin" ])
      log = log_for(incident)
      sign_in event_admin

      get admin_audit_log_path(log)

      expect(response).to have_http_status(:ok)
    end

    it "allows a global admin regardless of visibility" do
      incident = create_incident(visible_to_roles: [])
      log = log_for(incident)
      sign_in global_admin

      get admin_audit_log_path(log)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET index" do
    it "hides audit rows for incidents the event admin cannot view" do
      hidden = create_incident(visible_to_roles: [])
      visible = create_incident(visible_to_roles: [ "event_admin" ])
      log_for(hidden)
      log_for(visible)
      sign_in event_admin

      get admin_audit_logs_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(visible.id.first(8))
      expect(response.body).not_to include(hidden.id.first(8))
    end

    it "does not let an event admin read another event's logs via event_id param" do
      other_event = create(:event)
      other_incident = Incident.create!(
        event: other_event, reported_by: reporter, category: "behavior", severity: "low",
        summary: "Other event", visible_to_roles: [ "event_admin" ]
      )
      AuditLog.log!(action: "update", record: other_incident, actor: reporter, event: other_event)
      sign_in event_admin

      get admin_audit_logs_path(event_id: other_event.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(other_incident.id.first(8))
    end

    it "shows all incident rows to a global admin" do
      hidden = create_incident(visible_to_roles: [])
      log_for(hidden)
      sign_in global_admin

      get admin_audit_logs_path

      expect(response.body).to include(hidden.id.first(8))
    end
  end

  describe "GET versions" do
    it "is not accessible to event admins" do
      sign_in event_admin

      get versions_admin_audit_logs_path

      expect(response).to redirect_to(admin_audit_logs_path)
    end

    it "is accessible to global admins" do
      sign_in global_admin

      get versions_admin_audit_logs_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe "sensitive content capture" do
    it "does not version incident free-text fields via PaperTrail" do
      incident = nil
      PaperTrail.request(whodunnit: reporter.id) do
        incident = create_incident(visible_to_roles: [])
        incident.update!(summary: "updated secret", severity: "high")
      end

      changesets = incident.versions.map(&:changeset)
      expect(changesets.flat_map(&:keys)).not_to include("summary", "details", "actions_taken")
      expect(changesets.last).to have_key("severity")
      expect(incident.versions.map(&:object).compact.join).not_to include("Confidential", "secret")
    end

    it "does not version incident comment bodies" do
      incident = create_incident(visible_to_roles: [])
      comment = IncidentComment.create!(incident: incident, user: reporter, body: "very secret")

      expect(comment.versions.flat_map { |v| v.changeset.keys }).not_to include("body")
    end

    it "redacts encrypted fields from AuditLog changed_fields on admin updates" do
      incident = create_incident(visible_to_roles: [ "event_admin" ])
      sign_in global_admin
      # Consume Devise trackable's first-request update so the incident is the
      # changed record log_admin_action picks up.
      get admin_event_incident_path(event_slug: event.slug, id: incident.id)

      patch admin_event_incident_path(event_slug: event.slug, id: incident.id),
        params: { incident: { summary: "new secret summary", severity: "high" } }

      log = AuditLog.where(record_type: "Incident", record_id: incident.id, action: "update").last
      expect(log).to be_present
      expect(log.changed_fields["summary"]).to eq("[REDACTED]")
      expect(log.changed_fields.to_json).not_to include("new secret summary")
      expect(log.changed_fields["severity"]).to eq([ "low", "high" ])
    end
  end
end
