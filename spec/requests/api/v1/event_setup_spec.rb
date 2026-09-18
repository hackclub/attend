require "rails_helper"

RSpec.describe "Api::V1::EventSetup", type: :request do
  let(:series) { create(:event_series, name: "Sunbeam", slug: "sunbeam-setup-api") }
  let(:event) { create(:event, :draft, event_series: series, docuseal_waiver_template_id: nil) }

  let(:global_admin) { User.create!(email: "ga-setup-api@example.com", name: "GA", global_role: "global_admin") }
  let(:series_owner) do
    User.create!(email: "owner-setup-api@example.com", name: "Owner").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
    end
  end

  def user_headers(user)
    { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" }
  end

  let(:event_key_headers) do
    { "Authorization" => "Bearer #{EventApiToken.generate_for(event, user: series_owner, name: 'setup').token}" }
  end
  let(:series_key_headers) do
    { "Authorization" => "Bearer #{SeriesApiToken.generate_for(series, user: series_owner, name: 'setup').token}" }
  end

  describe "GET /api/v1/events/:event_id/setup" do
    it "reports which wizard steps are still outstanding" do
      get "/api/v1/events/#{event.slug}/setup", headers: user_headers(global_admin)

      expect(response).to have_http_status(:ok)
      setup = JSON.parse(response.body)["setup"]
      expect(setup["complete"]).to be(false)
      expect(setup["steps"]).to include("basics" => true, "schedule" => true, "waivers" => false, "team" => false)
      expect(setup["remaining"]).to match_array(%w[waivers team])
    end

    it "404s for an event that doesn't exist" do
      get "/api/v1/events/not-a-real-event/setup", headers: user_headers(global_admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PUT /api/v1/events/:event_id/setup/waivers" do
    it "clones the default DocuSeal templates in auto mode" do
      event.update!(freedom_waivers_enabled: true)
      # The real service against a stubbed DocuSeal, so the response reflects
      # the template ids it actually wrote rather than ones the stub invented.
      client = instance_double(Docuseal::Client)
      allow(Docuseal::HostConfig).to receive(:default_host).and_return("https://docuseal.example.com")
      allow(Docuseal::Client).to receive(:new).and_return(client)
      allow(client).to receive(:clone_template).and_return({ "id" => 11 }, { "id" => 22 })

      put "/api/v1/events/#{event.id}/setup/waivers", params: { mode: "auto" }, headers: series_key_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["created"]).to match_array(%w[waiver freedom_waiver])
      expect(body["waivers"]).to include("docuseal_waiver_template_id" => "11", "docuseal_freedom_waiver_template_id" => "22")
      expect(AuditLog.find_by(action: "update_waivers", event: event).metadata["mode"]).to eq("auto")
    end

    it "only sets up the freedom waiver when that module is on" do
      event.update!(freedom_waivers_enabled: false)
      allow_any_instance_of(Docuseal::DefaultTemplateSetup).to receive(:call)
        .and_return(Docuseal::DefaultTemplateSetup::Result.new(true, "ok"))

      put "/api/v1/events/#{event.id}/setup/waivers", params: { mode: "auto" }, headers: user_headers(global_admin)

      expect(JSON.parse(response.body)["created"]).to eq(%w[waiver])
    end

    it "answers 502 when DocuSeal refuses, so the caller knows to retry rather than fix its request" do
      allow_any_instance_of(Docuseal::DefaultTemplateSetup).to receive(:call)
        .and_return(Docuseal::DefaultTemplateSetup::Result.new(false, "Failed to use default template: boom"))

      put "/api/v1/events/#{event.id}/setup/waivers", params: { mode: "auto" }, headers: user_headers(global_admin)

      expect(response).to have_http_status(:bad_gateway)
      expect(JSON.parse(response.body)["error"]).to include("boom")
    end

    it "stores hand-made template ids in manual mode and warns about field mappings" do
      put "/api/v1/events/#{event.id}/setup/waivers",
        params: { mode: "manual", docuseal_waiver_template_id: 903 },
        headers: event_key_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["waivers"]["docuseal_waiver_template_id"]).to eq("903")
      expect(body["warning"]).to include("Field mappings")
      expect(event.reload.docuseal_waiver_template_id).to eq("903")
    end

    it "leaves the template it wasn't told about alone" do
      event.update!(docuseal_freedom_waiver_template_id: 77)

      put "/api/v1/events/#{event.id}/setup/waivers",
        params: { mode: "manual", docuseal_waiver_template_id: 903 },
        headers: user_headers(global_admin)

      expect(event.reload.docuseal_freedom_waiver_template_id).to eq("77")
    end

    it "rejects a mode it doesn't understand, and a manual call with nothing in it" do
      put "/api/v1/events/#{event.id}/setup/waivers", params: { mode: "later" }, headers: user_headers(global_admin)
      expect(response).to have_http_status(:unprocessable_entity)

      put "/api/v1/events/#{event.id}/setup/waivers", params: { mode: "manual" }, headers: user_headers(global_admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("mode=auto")
    end
  end

  describe "POST /api/v1/events/:event_id/setup/complete" do
    it "flips the event out of draft" do
      post "/api/v1/events/#{event.id}/setup/complete", headers: series_key_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["setup"]["complete"]).to be(true)
      expect(event.reload.setup_complete?).to be(true)
      log = AuditLog.find_by(action: "complete", event: event)
      expect(log.metadata["source"]).to eq("series_api")
    end

    it "is a no-op on an event that is already set up" do
      completed = create(:event, event_series: series, setup_completed_at: 3.days.ago)

      expect {
        post "/api/v1/events/#{completed.id}/setup/complete", headers: series_key_headers
      }.not_to change { completed.reload.setup_completed_at }

      expect(response).to have_http_status(:ok)
    end

    it "refuses without a support email, which every participant email is sent from" do
      event.update_columns(support_email: nil)

      post "/api/v1/events/#{event.id}/setup/complete", headers: user_headers(global_admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("support email")
      expect(event.reload.setup_complete?).to be(false)
    end

    it "refuses an event API key issued for another event" do
      other_event = create(:event, :draft)

      post "/api/v1/events/#{other_event.id}/setup/complete", headers: event_key_headers

      expect(response).to have_http_status(:forbidden)
      expect(other_event.reload.setup_complete?).to be(false)
    end

    it "refuses a staff member with no standing on the event" do
      outsider = create(:event_role_assignment, role: "event_admin").user

      post "/api/v1/events/#{event.id}/setup/complete", headers: user_headers(outsider)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
