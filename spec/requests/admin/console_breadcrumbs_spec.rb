require "rails_helper"

# Every page in the Cloudscape admin console carries one breadcrumb trail:
# event pages hang off Events › {event}, global pages off their own section,
# the last crumb is the current page as text, and every crumb before it links.
RSpec.describe "Admin console breadcrumbs", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) do
    User.create!(email: "crumb-admin@example.com", name: "Robin Placeholder",
      global_role: "global_admin", admin_console_beta: true)
  end
  let(:event) do
    create(:event, name: "Breadcrumb Test Jam", travel_enabled: true,
      accommodation_enabled: true, groups_enabled: true)
  end
  let(:participant) { create(:participant, legal_first_name: "Fictional", legal_last_name: "Attendee") }
  let!(:participant_event) { create(:participant_event, event: event, participant: participant) }
  let(:participant_label) { participant.display_name }
  let!(:incident) do
    Incident.create!(event: event, reported_by: admin, category: :other, severity: :low,
      summary: "A made-up incident")
  end
  let!(:change_request) do
    RegistrationChangeRequest.create!(participant_event: participant_event, requested_by: admin,
      kind: :support, staff_audience: :event_admin, requester_note: "Made-up note")
  end
  let(:series) { create(:event_series, name: "Placeholder Series") }
  let(:other_user) { User.create!(email: "crumb-other@example.com", name: "Sam Sample") }

  # [label, linked?] pairs, in order.
  def crumbs
    groups = Nokogiri::HTML(response.body).css(".cs-breadcrumbs")
    expect(groups.size).to eq(1), "expected exactly one .cs-breadcrumbs, got #{groups.size}"
    groups.first.css("li").map do |li|
      link = li.at_css("a")
      { label: li.text.strip, link: link&.[]("href"), current: li.at_css("[aria-current='page']").present? }
    end
  end

  def expect_trail(path, *labels)
    get path
    expect(response).to have_http_status(:ok), "GET #{path} returned #{response.status}"
    trail = crumbs
    expect(trail.map { |c| c[:label] }).to eq(labels), "trail on #{path}"
    *parents, last = trail
    expect(last[:current]).to be(true), "last crumb on #{path} should be aria-current=page"
    expect(last[:link]).to be_nil, "last crumb on #{path} should not link"
    parents.each do |crumb|
      expect(crumb[:link]).to be_present, "crumb #{crumb[:label].inspect} on #{path} should link"
      expect(crumb[:current]).to be(false)
    end
    trail
  end

  describe "as a global admin" do
    before { sign_in admin }

    it "roots event pages at Events › {event}" do
      e = [ "Events", event.name ]

      expect_trail admin_root_path, "Events"
      expect_trail admin_event_dashboard_path(event.slug), *e
      expect_trail admin_event_participants_path(event), *e, "Participants"
      expect_trail table_admin_event_participants_path(event), *e, "Participants"
      expect_trail admin_event_participant_path(event, participant_event), *e, "Participants", participant_label
      expect_trail travel_admin_event_participant_path(event, participant_event), *e, "Participants", participant_label, "Travel"
      expect_trail safeguarding_admin_event_participant_path(event, participant_event), *e, "Participants", participant_label, "Safeguarding"
      expect_trail admin_event_incidents_path(event), *e, "Incidents"
      expect_trail admin_event_incident_path(event, incident), *e, "Incidents", "Incident details"
      expect_trail new_admin_event_incident_path(event), *e, "Incidents", "New incident"
      expect_trail admin_event_scans_path(event), *e, "Check-ins"
      expect_trail admin_event_scan_contexts_path(event), *e, "Check-ins", "Scan contexts"
      expect_trail admin_event_travel_path(event), *e, "Travel calendar"
      expect_trail setup_admin_event_rooming_wizard_path(event.slug), *e, "Rooming"
      expect_trail admin_event_groups_path(event), *e, "Groups"
      expect_trail admin_event_messages_path(event), *e, "Messages"
      expect_trail new_admin_event_message_path(event), *e, "Messages", "Compose message"
      expect_trail admin_event_registration_change_requests_path(event), *e, "Change requests"
      expect_trail admin_event_registration_change_request_path(event, change_request), *e, "Change requests", participant_label
      expect_trail admin_event_staff_index_path(event), *e, "Staff"
      expect_trail admin_event_exports_path(event), *e, "Exports"
      expect_trail admin_event_integrations_path(event.slug), *e, "Integrations"
      expect_trail edit_admin_event_path(event), *e, "Event settings"
      expect_trail admin_event_setup_schedule_path(event), *e, "Setup"
      expect_trail admin_audit_logs_path(event_id: event.id), *e, "Event audit log"
    end

    it "links event crumbs to the events list and the event dashboard" do
      trail = expect_trail admin_event_incident_path(event, incident), "Events", event.name, "Incidents", "Incident details"

      expect(trail.map { |c| c[:link] }.first(3)).to eq([
        admin_root_path, admin_event_dashboard_path(event.slug), admin_event_incidents_path(event)
      ])
    end

    it "starts a new event at Events › New event" do
      expect_trail admin_new_event_path, "Events", "New event"
    end

    it "roots global pages at their own section" do
      expect_trail admin_users_path, "Users"
      expect_trail admin_user_path(other_user), "Users", other_user.display_name_or_fallback
      expect_trail admin_series_index_path, "Event series"
      expect_trail admin_series_path(series), "Event series", series.name
      expect_trail admin_settings_path, "Settings"
      expect_trail admin_global_api_tokens_path, "API tokens"
      expect_trail admin_audit_logs_path, "Audit log"
      expect_trail admin_bans_path, "Ban list"
      expect_trail admin_incidents_path, "Incident reports"
    end
  end

  describe "as an ops staff member" do
    let(:ops) do
      User.create!(email: "crumb-ops@example.com", name: "Alex Example", admin_console_beta: true).tap do |user|
        EventRoleAssignment.create!(user: user, event: event, role: "ops")
      end
    end

    before { sign_in ops }

    it "only links crumbs whose targets they can open" do
      # Integrations is gated on manage_integrations?, which ops passes.
      trail = expect_trail admin_event_setup_waivers_path(event, return_to: "integrations"),
        "Events", event.name, "Integrations", "Set up waivers"

      trail.filter_map { |c| c[:link] }.each do |href|
        get href
        expect(response).to have_http_status(:ok), "crumb link #{href} returned #{response.status} for ops"
      end
    end

    it "leaves the safeguarding crumb unlinked when the policy refuses it" do
      # Ops can't open the Safeguarding tab; build the trail in the helper the
      # way emergency-contact pages do and check it never links there.
      get travel_admin_event_participant_path(event, participant_event)
      expect(response).to have_http_status(:ok)
      helper = controller.view_context
      html = helper.cs_event_breadcrumbs(
        helper.cs_gated_crumb("Safeguarding",
          helper.safeguarding_admin_event_participant_path(event, participant_event),
          helper.policy(participant_event).view_safeguarding?),
        [ "Add emergency contact", nil ],
        event: event
      )
      doc = Nokogiri::HTML.fragment(html)
      safeguarding = doc.css("li").find { |li| li.text.strip == "Safeguarding" }
      expect(safeguarding.at_css("a")).to be_nil
      expect(doc.css("a").map { |a| a["href"] }).not_to include(a_string_including("/safeguarding"))
    end
  end

  describe "as an event admin of a different event" do
    let(:other_event) { create(:event, name: "Unrelated Jam") }
    let(:outsider) do
      User.create!(email: "crumb-outsider@example.com", name: "Jo Fiction", admin_console_beta: true).tap do |user|
        EventRoleAssignment.create!(user: user, event: other_event, role: "event_admin")
      end
    end

    before { sign_in outsider }

    it "doesn't name or link an event they can't open in the audit log trail" do
      expect_trail admin_audit_logs_path(event_id: event.id), "Audit log"
      expect(response.body).not_to include(event.name)
    end
  end
end
