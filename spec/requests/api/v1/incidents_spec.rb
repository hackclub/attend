require "rails_helper"

RSpec.describe "Api::V1::Incidents", type: :request do
  include ActiveJob::TestHelper

  let(:event) { create(:event, starts_at: 1.day.ago, ends_at: 1.day.from_now) }

  def staff(role, email)
    create(:user, name: role.humanize, email: email).tap do |user|
      EventRoleAssignment.create!(user: user, event: event, role: role)
    end
  end

  def headers_for(user)
    { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" }
  end

  let(:event_admin) { staff("event_admin", "ea-api-incidents@example.com") }
  let(:ops) { staff("ops", "ops-api-incidents@example.com") }
  let(:headers) { headers_for(event_admin) }
  let(:json) { JSON.parse(response.body) }

  let(:incident_params) do
    { category: "behavior", severity: "s2", status: "open", summary: "Shoving in the queue",
      details: "Two attendees shoved each other.", visible_to_roles: [ "event_admin" ] }
  end
  let(:escalation_params) { { reporter_phone: "+14155550177", emergency_services_called: false } }

  describe "GET index" do
    it "lists only the incidents the caller's roles can see" do
      shared = create(:incident, event: event, visible_to_roles: [ "ops" ])
      create(:incident, event: event, visible_to_roles: [ "safeguarding_lead" ])

      get api_v1_event_incidents_path(event), headers: headers_for(ops)

      expect(response).to have_http_status(:ok)
      expect(json["incidents"].map { |i| i["id"] }).to eq([ shared.id ])
    end

    it "refuses someone with no role on the event" do
      outsider = create(:user, email: "outsider-api-incidents@example.com")
      get api_v1_event_incidents_path(event), headers: headers_for(outsider)

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses an event API key" do
      event.generate_api_key!
      get api_v1_event_incidents_path(event), headers: { "Authorization" => "Bearer #{event.api_key}" }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET options" do
    it "offers the scale, roles and the people on the event" do
      pe = create(:participant_event, event: event)
      ops

      get options_api_v1_event_incidents_path(event), headers: headers

      expect(response).to have_http_status(:ok)
      expect(json["levels"].map { |l| l["value"] }).to eq(%w[s0 s1 s2 s3])
      expect(json["default_visible_to_roles"]).to eq(Incident::DEFAULT_VISIBLE_TO_ROLES)
      expect(json["participants"].map { |p| p["id"] }).to eq([ pe.id ])
      expect(json["staff"].map { |s| s["id"] }).to contain_exactly(event_admin.id, ops.id)
    end
  end

  describe "POST create" do
    it "logs an incident reported by the caller without involving HQ" do
      expect {
        post api_v1_event_incidents_path(event), params: { incident: incident_params }, headers: headers, as: :json
      }.to change(Incident, :count).by(1).and not_change(IncidentReport, :count)

      expect(response).to have_http_status(:created)
      expect(Incident.last.reported_by).to eq(event_admin)
      expect(json["incident"]).to include("summary" => "Shoving in the queue", "hq_report" => nil)
      expect(AuditLog.where(record: Incident.last, action: :record_create)).to exist
    end

    it "logs and escalates in one go when asked" do
      expect {
        post api_v1_event_incidents_path(event),
          params: { incident: incident_params, escalate: true, escalation: escalation_params }, headers: headers, as: :json
      }.to change(IncidentReport, :count).by(1)
        .and have_enqueued_job(SendIncidentReportToSlackJob)
        .and have_enqueued_job(SendIncidentToSlackJob)

      expect(Incident.last.hq_report).to have_attributes(priority: "s2", reporter_phone: "+14155550177")
      expect(json["notice"]).to eq("Incident logged and escalated to Hack Club HQ.")
    end

    it "saves nothing when the escalation half is invalid" do
      expect {
        post api_v1_event_incidents_path(event),
          params: { incident: incident_params, escalate: true, escalation: { reporter_phone: "" } }, headers: headers, as: :json
      }.not_to change(Incident, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["errors"].join).to include("Escalation:")
    end

    it "holds medical incidents to their links" do
      post api_v1_event_incidents_path(event), params: { incident: incident_params.merge(category: "medical") }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["errors"]).to include("Medical incidents must be linked to at least one participant")
    end
  end

  describe "GET show" do
    it "gives a reporter outside the shared roles a receipt, not the casework" do
      incident = create(:incident, event: event, reported_by: ops, visible_to_roles: [ "event_admin" ], actions_taken: "Called parents")
      incident.comments.create!(user: event_admin, body: "Handled")

      get api_v1_event_incident_path(event, incident), headers: headers_for(ops)

      expect(response).to have_http_status(:ok)
      expect(json["incident"]).to include("actions_taken" => nil, "timeline" => [])
      expect(json["incident"]["permissions"]).to include("update" => false, "comment" => true, "view_casework" => false)
    end

    it "shows the timeline to the roles it's shared with" do
      incident = create(:incident, event: event, actions_taken: "Called parents")
      incident.comments.create!(user: event_admin, body: "Handled", new_status: "closed")

      get api_v1_event_incident_path(event, incident), headers: headers

      expect(json["incident"]["actions_taken"]).to eq("Called parents")
      expect(json["incident"]["timeline"].first).to include("type" => "comment", "body" => "Handled", "new_status" => "closed")
    end
  end

  describe "PATCH update" do
    it "updates for a role the incident is shared with" do
      incident = create(:incident, event: event)

      patch api_v1_event_incident_path(event, incident), params: { incident: { status: "in_review" } }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(incident.reload.status).to eq("in_review")
    end

    it "refuses a reporter who holds none of its roles" do
      incident = create(:incident, event: event, reported_by: ops, visible_to_roles: [ "event_admin" ])

      patch api_v1_event_incident_path(event, incident), params: { incident: { status: "closed" } }, headers: headers_for(ops), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(incident.reload.status).to eq("open")
    end
  end

  describe "POST escalate" do
    it "escalates once and answers the same on a repeat" do
      incident = create(:incident, event: event)

      expect {
        2.times do
          post escalate_api_v1_event_incident_path(event, incident), params: { escalation: escalation_params }, headers: headers, as: :json
        end
      }.to change(IncidentReport, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(json["notice"]).to eq("This incident has already been escalated to Hack Club HQ.")
      expect(json["incident"]["hq_report"]).to include("status" => "open")
    end
  end

  describe "POST comments" do
    it "drops a status change from someone who can't update the incident" do
      incident = create(:incident, event: event, reported_by: ops, visible_to_roles: [ "event_admin" ])

      post api_v1_event_incident_comments_path(event, incident),
        params: { comment: { body: "More detail", new_status: "closed" } }, headers: headers_for(ops), as: :json

      expect(response).to have_http_status(:created)
      expect(incident.reload.status).to eq("open")
      expect(incident.comments.last.body).to eq("More detail")
    end

    it "applies a status change from a handler" do
      incident = create(:incident, event: event)

      post api_v1_event_incident_comments_path(event, incident),
        params: { comment: { body: "Resolved", new_status: "closed" } }, headers: headers, as: :json

      expect(json["incident_status"]).to eq("closed")
    end

    it "refuses an unknown status before writing anything" do
      incident = create(:incident, event: event)

      expect {
        post api_v1_event_incident_comments_path(event, incident),
          params: { comment: { body: "Hmm", new_status: "bogus" } }, headers: headers, as: :json
      }.not_to change(IncidentComment, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
