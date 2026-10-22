require "rails_helper"

RSpec.describe "Admin::IncidentReports (HQ inbox)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, name: "Example Camp") }
  let(:other_event) { create(:event, name: "Other Camp") }
  let(:global_admin) { create(:user, email: "ga-inbox@example.com", global_role: "global_admin") }
  let(:event_admin) do
    create(:user, email: "ea-inbox@example.com").tap { |u| EventRoleAssignment.create!(user: u, event: event, role: "event_admin") }
  end

  let!(:public_report) { create(:incident_report, event: event, summary: "Filed from the public form") }
  let!(:log_entry) { create(:incident, event: event, reported_by: event_admin, summary: "Only in the event log", visible_to_roles: %w[ops]) }
  let!(:escalated) do
    create(:incident, event: other_event, reported_by: event_admin, summary: "Escalated entry").tap do |incident|
      create(:incident_report, event: other_event, incident: incident, user: event_admin, summary: "HQ copy of escalated entry", status: "in_review")
    end
  end

  it "shows reports to HQ and every event's incident log to a global admin" do
    sign_in global_admin
    get admin_incident_reports_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Filed from the public form", "Only in the event log", "Escalated entry")
    expect(response.body).to include("Escalated from event log", "Public form")
    expect(response.body).to include(admin_event_incident_path(other_event, escalated))
  end

  it "filters the log section by event and open status" do
    sign_in global_admin
    log_entry.update!(status: "closed")

    get admin_incident_reports_path(view: "logs", event_id: event.id)
    expect(response.body).to include("Only in the event log")
    expect(response.body).not_to include("Filed from the public form")

    get admin_incident_reports_path(view: "logs", event_id: event.id, open: "1")
    expect(response.body).not_to include("Only in the event log")
  end

  it "links an escalated report back to its incident" do
    sign_in global_admin
    get admin_incident_report_path(escalated.hq_report)
    expect(response.body).to include(admin_event_incident_path(other_event, escalated))
  end

  it "turns away event admins" do
    sign_in event_admin
    get admin_incident_reports_path
    expect(response).to have_http_status(:redirect)
    expect(response.body).not_to include("Filed from the public form")
  end

  context "with the admin console beta" do
    before { global_admin.update!(admin_console_beta: true) }

    it "renders the same inbox" do
      sign_in global_admin
      get admin_incident_reports_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("HQ incident inbox", "Only in the event log", "Escalated from event log")
    end
  end
end
