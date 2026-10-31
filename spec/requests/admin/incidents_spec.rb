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
  let(:participant_event) { create(:participant_event, event: event) }
  let(:medical_params) do
    incident_params.merge(category: "medical", participant_event_ids: [ participant_event.id ], helping_staff_ids: [ ops.id ])
  end

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
        post admin_event_incidents_path(event), params: { incident: medical_params, escalate: "1", escalation: escalation_params }
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

    it "records dispensed medication on a medical incident" do
      expect {
        post admin_event_incidents_path(event), params: {
          incident: medical_params.merge(
            medication_dispensed: "1",
            medications_attributes: { "0" => { name: "Paracetamol", dose: "2 x 500mg", notes: "After lunch" } }
          )
        }
      }.to change(IncidentMedication, :count).by(1)

      incident = Incident.last
      expect(response).to redirect_to(admin_event_incident_path(event, incident))
      expect(incident.medication_dispensed).to be(true)

      get admin_event_incident_path(event, incident)
      expect(response.body).to include("Paracetamol", "2 x 500mg", "After lunch")
    end

    it "rejects a medical incident without a participant or staff member" do
      expect {
        post admin_event_incidents_path(event), params: { incident: incident_params.merge(category: "medical") }
      }.not_to change(Incident, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Medical incidents must be linked to at least one participant")
      expect(response.body).to include("Medical incidents must be linked to at least one staff member")
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

  describe "occurred_at on the event's clock" do
    let(:event) { create(:event, starts_at: 1.day.ago, ends_at: 1.day.from_now, timezone: "Eastern Time (US & Canada)") }

    def log_incident(occurred_at)
      create(:incident, event: event, reported_by: event_admin, visible_to_roles: %w[event_admin], occurred_at: occurred_at)
    end

    it "reads a typed time in the event's time zone" do
      post admin_event_incidents_path(event), params: { incident: incident_params.merge(occurred_at: "2026-07-12T21:30") }

      incident = Incident.last
      expect(incident.occurred_at).to eq(Time.utc(2026, 7, 13, 1, 30))
      expect(incident.times_in_event_zone).to be(true)
    end

    it "gives HQ the event-local time when escalating in the same go" do
      post admin_event_incidents_path(event), params: {
        incident: incident_params.merge(occurred_at: "2026-07-12T21:30"), escalate: "1", escalation: escalation_params
      }

      expect(Incident.last.hq_report.details).to include("Occurred at: 2026-07-12 21:30 EDT")
    end

    it "updates the time on the event's clock" do
      incident = log_incident("2026-07-12T21:30")

      patch admin_event_incident_path(event, incident), params: { incident: { occurred_at: "2026-07-12T22:15" } }

      expect(response).to redirect_to(admin_event_incident_path(event, incident))
      expect(incident.reload.occurred_at).to eq(Time.utc(2026, 7, 13, 2, 15))
    end

    it "moves a legacy row onto the event's clock when its form is saved" do
      incident = log_incident(nil)
      incident.update_columns(occurred_at: Time.utc(2026, 7, 12, 21, 30), times_in_event_zone: false)

      get edit_admin_event_incident_path(event, incident)
      prefill = Nokogiri::HTML(response.body).at_css("input[name='incident[occurred_at]']")["value"]
      expect(prefill).to eq("2026-07-12T21:30")

      patch admin_event_incident_path(event, incident), params: { incident: { occurred_at: prefill } }

      incident.reload
      expect(incident.times_in_event_zone).to be(true)
      expect(incident.local_time(:occurred_at).strftime("%Y-%m-%d %H:%M %Z")).to eq("2026-07-12 21:30 EDT")
    end

    it "does not tell Slack an untouched time was edited" do
      incident = log_incident("2026-07-12T21:30")
      incident.update_columns(slack_message_ts: "1700000000.000100")

      expect {
        patch admin_event_incident_path(event, incident), params: {
          incident: { occurred_at: incident.local_time_field_value(:occurred_at), summary: "Pushing in the queue" }
        }
      }.to have_enqueued_job(SendIncidentUpdateToSlackJob).with { |_incident_id, _user_id, changes|
        expect(changes.keys).to include("summary")
        expect(changes.keys).not_to include("occurred_at", "times_in_event_zone")
      }
    end

    {
      "the original UI" => { console: false, show: "July 12, 2026 at 21:30", index: "Jul 12, 2026 21:30" },
      "the console" => { console: true, show: "July 12, 2026, 21:30 (UTC-4:00)", index: "July 12, 2026, 21:30 (UTC-4:00)" }
    }.each do |ui, expected|
      context "in #{ui}" do
        before { event_admin.update!(admin_console_beta: expected[:console]) }

        it "prefills and labels the field on the event's clock, in 24-hour time" do
          incident = log_incident("2026-07-12T21:30")

          get edit_admin_event_incident_path(event, incident)

          page = Nokogiri::HTML(response.body)
          field = page.at_css("input[name='incident[occurred_at]']")
          expect(field["value"]).to eq("2026-07-12T21:30")
          expect(field["lang"]).to eq("en-GB")
          expect(page.text).to include("In the event's time zone: Eastern Time (US & Canada).")
        end

        it "shows the time on the event's clock" do
          incident = log_incident("2026-07-12T21:30")

          get admin_event_incident_path(event, incident)
          expect(response.body).to include(expected[:show])

          get admin_event_incidents_path(event)
          expect(response.body).to include(expected[:index])
        end

        it "keeps showing a legacy row on UTC" do
          incident = log_incident(nil)
          incident.update_columns(occurred_at: Time.utc(2026, 7, 12, 21, 30), times_in_event_zone: false)

          get admin_event_incident_path(event, incident)
          expect(response.body).to include(expected[:show].sub("UTC-4:00", "UTC+0:00"))
        end
      end
    end
  end

  describe "GET new" do
    it "pre-ticks the default roles" do
      get new_admin_event_incident_path(event)
      expect(response.body).to include('value="event_admin" checked', 'value="safeguarding_lead" checked')
    end

    it "renders the medication fields" do
      get new_admin_event_incident_path(event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("incident[medication_dispensed]")
      expect(response.body).to include("incident[medications_attributes][NEW_RECORD][name]")
    end
  end
end
