require "rails_helper"

RSpec.describe "Admin::EventSetup", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-setup@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event, :draft) }

  before { sign_in admin }

  describe "POST /admin/events (step 1)" do
    it "creates a draft event and redirects into the wizard" do
      post admin_events_path, params: { event: { name: "Wizard Con", slug: "wizard-con", support_email: "wizard@hackclub.com" } }

      created = Event.find_by(slug: "wizard-con")
      expect(created.setup_complete?).to be(false)
      expect(response).to redirect_to(admin_event_setup_schedule_path(created))
    end

    it "rejects a draft without a support email" do
      post admin_events_path, params: { event: { name: "No Mail Con", slug: "no-mail-con" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Event.find_by(slug: "no-mail-con")).to be_nil
    end

    it "rejects a support email outside the Hack Club domains" do
      post admin_events_path, params: {
        event: { name: "Outside Con", slug: "outside-con", support_email: "hi@gmail.com" }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Event.find_by(slug: "outside-con")).to be_nil
      expect(response.body).to include("@hackclub.com or @events.hackclub.com")
    end
  end

  describe "GET setup (resume)" do
    it "resumes at schedule when dates are missing" do
      event.update!(starts_at: nil, ends_at: nil)

      get admin_event_setup_path(event)

      expect(response).to redirect_to(admin_event_setup_schedule_path(event))
    end

    it "resumes at waivers when dates are set but no waiver template exists" do
      get admin_event_setup_path(event)

      expect(response).to redirect_to(admin_event_setup_waivers_path(event))
    end

    it "resumes at review when waivers are configured" do
      event.update!(docuseal_waiver_template_id: "123")

      get admin_event_setup_path(event)

      expect(response).to redirect_to(admin_event_setup_review_path(event))
    end
  end

  describe "step pages" do
    it "renders the progress bar on step 1 without links" do
      get admin_new_event_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Setup progress")
    end

    it "renders every step" do
      get admin_event_setup_schedule_path(event)
      expect(response).to have_http_status(:ok)

      get admin_event_setup_modules_path(event)
      expect(response).to have_http_status(:ok)

      get admin_event_setup_waivers_path(event)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("custom-waivers")

      get admin_event_setup_team_path(event)
      expect(response).to have_http_status(:ok)

      get admin_event_setup_review_path(event)
      expect(response).to have_http_status(:ok)
    end

    it "hides the freedom waiver field on the waivers step when the module is off" do
      event.update!(freedom_waivers_enabled: "0")

      get admin_event_setup_waivers_path(event)

      expect(response.body).not_to include("docuseal_freedom_waiver_template_id")
    end
  end

  describe "PATCH schedule" do
    it "updates dates and advances to modules" do
      patch admin_event_setup_schedule_path(event), params: {
        event: { starts_at: "2026-08-01T09:00", ends_at: "2026-08-03T18:00" }
      }

      expect(event.reload.starts_at).to be_present
      expect(response).to redirect_to(admin_event_setup_modules_path(event))
    end
  end

  describe "PATCH modules" do
    it "updates config toggles and advances to waivers" do
      patch admin_event_setup_modules_path(event), params: {
        event: { travel_enabled: "0", groups_enabled: "1", freedom_waivers_enabled: "0" }
      }

      event.reload
      expect(event.travel_enabled?).to be(false)
      expect(event.groups_enabled?).to be(true)
      expect(event.freedom_waivers_enabled?).to be(false)
      expect(response).to redirect_to(admin_event_setup_waivers_path(event))
    end
  end

  describe "PATCH waivers" do
    let(:success) { Docuseal::DefaultTemplateSetup::Result.new(true, "ok") }
    let(:failure) { Docuseal::DefaultTemplateSetup::Result.new(false, "nope") }
    let(:setup) { instance_double(Docuseal::DefaultTemplateSetup) }

    before { allow(Docuseal::DefaultTemplateSetup).to receive(:new).with(kind_of(Event)).and_return(setup) }

    context "auto mode" do
      it "sets up waiver and freedom waiver templates when freedom waivers are enabled" do
        allow(setup).to receive(:call).and_return(success)

        patch admin_event_setup_waivers_path(event), params: { waiver_mode: "auto" }

        expect(setup).to have_received(:call).with("waiver")
        expect(setup).to have_received(:call).with("freedom_waiver")
        expect(response).to redirect_to(admin_event_setup_team_path(event))
      end

      it "skips the freedom waiver blueprint when the module is disabled" do
        event.update!(freedom_waivers_enabled: "0")
        allow(setup).to receive(:call).and_return(success)

        patch admin_event_setup_waivers_path(event), params: { waiver_mode: "auto" }

        expect(setup).to have_received(:call).with("waiver")
        expect(setup).not_to have_received(:call).with("freedom_waiver")
      end

      it "re-renders with an alert when DocuSeal setup fails" do
        allow(setup).to receive(:call).and_return(failure)

        patch admin_event_setup_waivers_path(event), params: { waiver_mode: "auto" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("nope")
      end
    end

    context "manual mode" do
      it "persists the entered template IDs" do
        patch admin_event_setup_waivers_path(event), params: {
          waiver_mode: "manual",
          event: { docuseal_waiver_template_id: "111", docuseal_freedom_waiver_template_id: "222" }
        }

        event.reload
        expect(event.docuseal_waiver_template_id).to eq("111")
        expect(event.docuseal_freedom_waiver_template_id).to eq("222")
        expect(response).to redirect_to(admin_event_setup_team_path(event))
      end
    end

    context "skip mode" do
      it "advances without touching waiver config" do
        patch admin_event_setup_waivers_path(event), params: { waiver_mode: "skip" }

        expect(event.reload.docuseal_waiver_template_id).to be_nil
        expect(response).to redirect_to(admin_event_setup_team_path(event))
      end
    end

    context "standalone entry from integrations" do
      it "returns to the integrations page after saving" do
        patch admin_event_setup_waivers_path(event, return_to: "integrations"), params: { waiver_mode: "skip" }

        expect(response).to redirect_to(admin_event_integrations_path(event))
      end
    end
  end

  describe "DELETE remove_team_member" do
    let(:staff_user) { create(:user) }

    it "removes a regular staff member" do
      assignment = create(:event_role_assignment, event: event, user: staff_user, role: "event_admin")

      expect {
        delete admin_event_setup_team_member_path(event, assignment)
      }.to change(EventRoleAssignment, :count).by(-1)
    end

    it "refuses to remove a series member whose access is inherited" do
      series = create(:event_series)
      event.update!(event_series: series)
      create(:series_role_assignment, user: staff_user, event_series: series, role: "organizer")
      assignment = create(:event_role_assignment, event: event, user: staff_user, role: "event_admin")

      expect {
        delete admin_event_setup_team_member_path(event, assignment)
      }.not_to change(EventRoleAssignment, :count)

      expect(flash[:alert]).to include("inherited from the series")
    end
  end

  describe "POST complete" do
    it "refuses to finish setup while the support email is missing" do
      event.update_column(:support_email, nil)

      post admin_event_setup_complete_path(event)

      expect(response).to redirect_to(edit_admin_event_path(event))
      expect(event.reload.setup_complete?).to be(false)
    end

    it "marks setup complete and lands on the event dashboard" do
      post admin_event_setup_complete_path(event)

      expect(event.reload.setup_complete?).to be(true)
      expect(response).to redirect_to(admin_event_dashboard_path(event))
    end

    it "does not overwrite an existing completion timestamp" do
      completed_at = 2.days.ago.change(usec: 0)
      event.update!(setup_completed_at: completed_at)

      post admin_event_setup_complete_path(event)

      expect(event.reload.setup_completed_at).to eq(completed_at)
    end
  end

  describe "authorization" do
    it "denies non-admin users" do
      sign_in User.create!(email: "pleb@example.com", name: "Pleb")

      get admin_event_setup_path(event)

      expect(response).to redirect_to(root_path)
    end
  end
end
