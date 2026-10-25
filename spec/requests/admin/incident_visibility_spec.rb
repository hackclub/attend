require "rails_helper"

# Incidents are visible to the roles ticked on them, plus the staff member who
# reported them. Everywhere that lists or counts incidents goes through
# IncidentPolicy, so a role that isn't ticked sees nothing about them.
RSpec.describe "Admin::Incidents visibility", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }

  def staff(role, email: "#{role}-incidents-spec@example.com", console: false)
    User.create!(email: email, name: role.titleize, admin_console_beta: console).tap do |user|
      EventRoleAssignment.create!(user: user, event: event, role: role)
    end
  end

  def create_incident(reported_by:, visible_to_roles:, **attrs)
    Incident.create!(
      event: event, reported_by: reported_by, category: "safeguarding",
      severity: "s1", status: "open", summary: "Confidential summary",
      visible_to_roles: visible_to_roles, **attrs
    )
  end

  describe "GET new" do
    it "pre-ticks the default roles" do
      sign_in staff("limited")

      get new_admin_event_incident_path(event)

      expect(response).to have_http_status(:ok)
      checked = Nokogiri::HTML(response.body)
        .css("input[name='incident[visible_to_roles][]'][type=checkbox][checked]")
        .map { |input| input["value"] }
      expect(checked).to match_array(Incident::DEFAULT_VISIBLE_TO_ROLES)
    end
  end

  describe "POST create" do
    it "lets the reporter open an incident shared with none of their roles" do
      limited = staff("limited")
      sign_in limited

      post admin_event_incidents_path(event), params: {
        incident: { category: "behavior", severity: "s3", summary: "Lost badge", visible_to_roles: [ "" ] }
      }

      incident = Incident.last
      expect(incident.reported_by).to eq(limited)
      expect(incident.visible_to_roles).to eq([])
      expect(response).to redirect_to(admin_event_incident_path(event, incident))

      follow_redirect!
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH update" do
    it "clears every role when all of them are unticked" do
      admin = staff("event_admin")
      incident = create_incident(reported_by: admin, visible_to_roles: %w[event_admin ops])
      sign_in admin

      patch admin_event_incident_path(event, incident), params: { incident: { visible_to_roles: [ "" ] } }

      expect(incident.reload.visible_to_roles).to eq([])
    end
  end

  describe "visibility" do
    let(:reporter) { staff("limited") }
    let!(:incident) { create_incident(reported_by: reporter, visible_to_roles: [ "safeguarding_lead" ]) }

    it "shows the reporter their own incident" do
      sign_in reporter

      get admin_event_incidents_path(event)
      expect(response.body).to include(admin_event_incident_path(event, incident))

      get admin_event_incident_path(event, incident)
      expect(response).to have_http_status(:ok)
    end

    it "lets the reporter comment on it" do
      sign_in reporter

      post admin_event_incident_comments_path(event, incident), params: { incident_comment: { body: "Update" } }

      expect(incident.comments.last.body).to eq("Update")
    end

    it "doesn't let the reporter change who it's shared with" do
      sign_in reporter

      patch admin_event_incident_path(event, incident), params: { incident: { visible_to_roles: %w[safeguarding_lead limited] } }

      expect(incident.reload.visible_to_roles).to eq([ "safeguarding_lead" ])
    end

    # IncidentComment#update_incident_status applies new_status on create, so
    # the comment box is the other door onto the same change.
    it "doesn't let the reporter close it from the comment box" do
      sign_in reporter

      post admin_event_incident_comments_path(event, incident),
        params: { incident_comment: { body: "Closing this", new_status: "closed" } }

      expect(incident.comments.last.body).to eq("Closing this")
      expect(incident.reload.status).to eq("open")
    end

    # Option 2 from the PR discussion: a receipt, not the case file. The
    # follow-up is written by the people handling it, in both UIs.
    [ false, true ].each do |console|
      context(console ? "in the console" : "in the original admin") do
        before do
          incident.update!(actions_taken: "Spoke to the organiser")
          incident.comments.create!(
            user: staff("safeguarding_lead", email: "sl-writes-casework-#{console}@example.com"),
            body: "Contacted the guardian"
          )
        end

        it "shows the reporter what they filed without the casework" do
          reporter.update!(admin_console_beta: console)
          sign_in reporter

          get admin_event_incident_path(event, incident)

          expect(response).to have_http_status(:ok)
          expect(response.body).to include("Confidential summary")
          expect(response.body).not_to include("Spoke to the organiser")
          expect(response.body).not_to include("Contacted the guardian")
          expect(response.body).not_to include("Timeline")
        end

        it "shows the casework to staff the incident is shared with" do
          sign_in staff("safeguarding_lead", email: "sl-reads-casework-#{console}@example.com", console: console)

          get admin_event_incident_path(event, incident)

          expect(response.body).to include("Spoke to the organiser")
          expect(response.body).to include("Contacted the guardian")
          expect(response.body).to include("Timeline")
        end
      end
    end

    it "keeps the status dropdown off the reporter's comment box" do
      sign_in reporter

      get admin_event_incident_path(event, incident)

      expect(response.body).not_to include("incident_comment[new_status]")
    end

    it "hides it from other staff whose role isn't ticked" do
      other = staff("limited", email: "other-limited-incidents-spec@example.com")
      sign_in other

      get admin_event_incidents_path(event)
      expect(response.body).not_to include(admin_event_incident_path(event, incident))

      get admin_event_incident_path(event, incident)
      expect(response).to redirect_to(root_path)
    end

    it "drops the reporter's access once they no longer hold a role on the event" do
      # Series membership keeps them in the event, so it's IncidentPolicy that
      # has to turn them away.
      event.update!(event_series: create(:event_series))
      create(:series_role_assignment, event_series: event.event_series, user: reporter, role: "organizer")
      reporter.event_role_assignments.find_by!(event: event).destroy!
      sign_in reporter

      get admin_event_incident_path(event, incident)

      expect(response).to redirect_to(root_path)
    end
  end

  describe "event dashboard" do
    let(:participant_event) do
      create(:participant_event, event: event,
        participant: create(:participant, legal_first_name: "Testy", legal_last_name: "McFixture"))
    end

    before do
      create_incident(reported_by: staff("safeguarding_lead"), visible_to_roles: [ "safeguarding_lead" ],
        participant_event: participant_event)
    end

    [ false, true ].each do |console|
      context(console ? "in the console" : "in the original admin") do
        it "leaves out incidents the viewer can't see" do
          sign_in staff("event_admin", console: console)

          get admin_event_dashboard_path(event)

          expect(response).to have_http_status(:ok)
          expect(response.body).not_to include("McFixture")
        end

        it "lists incidents shared with the viewer's role" do
          sign_in staff("safeguarding_lead", email: "sl-viewer-incidents-spec@example.com", console: console)

          get admin_event_dashboard_path(event)

          expect(response.body).to include("McFixture")
        end

        # The activity feed reads the audit log, where "Create Incident, just
        # now, <reporter>" gives away an incident this viewer cannot open.
        it "leaves hidden incidents out of the activity feed" do
          hidden = event.incidents.first
          hidden_log = AuditLog.log!(action: "create", record: hidden, actor: hidden.reported_by, event: event)
          # Something the viewer may see, so a passing expectation below can't
          # just mean the panel didn't render.
          visible_log = AuditLog.log!(action: "update", record: participant_event,
            actor: hidden.reported_by, event: event)
          sign_in staff("ops", email: "ops-feed-incidents-spec@example.com", console: console)

          get admin_event_dashboard_path(event)

          expect(response).to have_http_status(:ok)
          expect(response.body).to include(admin_audit_log_path(visible_log))
          expect(response.body).not_to include(admin_audit_log_path(hidden_log))
        end

        it "keeps the activity feed for an incident shared with the viewer" do
          hidden = event.incidents.first
          log = AuditLog.log!(action: "create", record: hidden, actor: hidden.reported_by, event: event)
          sign_in staff("safeguarding_lead", email: "sl-feed-incidents-spec@example.com", console: console)

          get admin_event_dashboard_path(event)

          expect(response.body).to include(admin_audit_log_path(log))
        end
      end
    end
  end
end
