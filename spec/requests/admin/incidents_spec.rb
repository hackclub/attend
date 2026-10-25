require "rails_helper"

RSpec.describe "Admin::Incidents", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event, starts_at: 1.day.ago, ends_at: 1.day.from_now) }
  let(:event_admin) do
    create(:user, name: "Event Admin", email: "ea-incidents@example.com").tap do |user|
      EventRoleAssignment.create!(user: user, event: event, role: "event_admin")
    end
  end
  let(:ops) do
    create(:user, name: "Ops Person", email: "ops-incidents@example.com").tap do |user|
      EventRoleAssignment.create!(user: user, event: event, role: "ops")
    end
  end

  let(:incident_params) do
    { category: "behavior", severity: "s2", status: "open", summary: "Shoving in the queue",
      details: "Two attendees shoved each other.", visible_to_roles: [ "event_admin" ] }
  end
  let(:escalation_params) { { reporter_phone: "+14155550177", emergency_services_called: "0" } }

  before do
    sign_in event_admin
    get admin_event_incidents_path(event) # warm-up so audit rows attach to the right record
  end

  describe "POST create" do
    it "logs an incident without involving HQ by default" do
      expect {
        post admin_event_incidents_path(event), params: { incident: incident_params }
      }.to change(Incident, :count).by(1).and not_change(IncidentReport, :count)

      expect(response).to redirect_to(admin_event_incident_path(event, Incident.last))
      expect(Incident.last.reported_by).to eq(event_admin)
    end

    it "logs and escalates in one go when asked" do
      expect {
        post admin_event_incidents_path(event), params: { incident: incident_params, escalate: "1", escalation: escalation_params }
      }.to change(Incident, :count).by(1).and change(IncidentReport, :count).by(1)
        .and have_enqueued_job(SendIncidentReportToSlackJob)
        .and have_enqueued_job(SendIncidentToSlackJob)

      incident = Incident.last
      expect(incident.hq_report).to have_attributes(priority: "s2", reporter_phone: "+14155550177", user: event_admin)
      follow_redirect!
      expect(response.body).to include("Escalated to Hack Club HQ")
    end

    it "keeps medical escalations off the Firehouse channel" do
      expect {
        post admin_event_incidents_path(event), params: { incident: incident_params.merge(category: "medical"), escalate: "1", escalation: escalation_params }
      }.to have_enqueued_job(SendIncidentReportToSlackJob).and not_have_enqueued_job(SendIncidentToSlackJob)
    end

    it "refuses to create a half-done entry when the HQ report would be invalid" do
      expect {
        post admin_event_incidents_path(event), params: { incident: incident_params, escalate: "1", escalation: escalation_params.merge(reporter_phone: "") }
      }.to not_change(Incident, :count).and not_change(IncidentReport, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Escalation:")
    end

    it "strips the form's blank role placeholder" do
      post admin_event_incidents_path(event), params: { incident: incident_params.merge(visible_to_roles: [ "", "ops" ]) }
      expect(Incident.last.visible_to_roles).to eq([ "ops" ])
    end
  end

  describe "POST escalate" do
    let!(:incident) { create(:incident, event: event, reported_by: event_admin, visible_to_roles: %w[event_admin]) }

    it "files the HQ report, audit-logs it and shows HQ's status" do
      expect {
        post escalate_admin_event_incident_path(event, incident), params: { escalation: escalation_params }
      }.to change(IncidentReport, :count).by(1)

      expect(response).to redirect_to(admin_event_incident_path(event, incident))
      expect(incident.reload).to be_escalated
      expect(AuditLog.where(action: "escalate", record: incident, actor: event_admin)).to exist

      follow_redirect!
      expect(response.body).to include("Escalated to Hack Club HQ", "HQ status:")
      expect(response.body).not_to include("Open HQ report")
    end

    it "does nothing the second time" do
      post escalate_admin_event_incident_path(event, incident), params: { escalation: escalation_params }
      expect {
        post escalate_admin_event_incident_path(event, incident), params: { escalation: escalation_params }
      }.not_to change(IncidentReport, :count)
      expect(flash[:notice]).to include("already been escalated")
    end

    it "is refused for a role that cannot see the incident" do
      sign_in ops
      expect {
        post escalate_admin_event_incident_path(event, incident), params: { escalation: escalation_params }
      }.not_to change(IncidentReport, :count)
      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "GET new" do
    it "pre-ticks the default roles" do
      get new_admin_event_incident_path(event)
      expect(response.body).to include('value="event_admin" checked', 'value="safeguarding_lead" checked')
    end
  end
end
