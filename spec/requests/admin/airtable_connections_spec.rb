require "rails_helper"

RSpec.describe "Admin::AirtableConnections", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:admin) { User.create!(email: "admin-airtable-oauth@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) do
    create(:event,
      airtable_api_key: "patFictionalLegacy",
      airtable_sync_source_id: "sncTest",
      airtable_sync_table_id: "tblTest",
      config: { "airtable_base_id" => "appTest" })
  end

  before do
    sign_in admin
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:airtable, :oauth_client_id).and_return("fictional-client")
    allow(Rails.application.credentials).to receive(:dig).with(:airtable, :oauth_client_secret).and_return("fictional-secret")
  end

  def start_connect
    post admin_event_airtable_connection_path(event)
    Rack::Utils.parse_query(URI.parse(response.location).query)
  end

  def stub_airtable(token_status: 200)
    stub_request(:post, "https://airtable.com/oauth2/v1/token").to_return(
      status: token_status,
      body: if token_status == 200
              { access_token: "fictional-access", refresh_token: "fictional-refresh", scope: Airtable::Oauth::SCOPE,
                expires_in: 3600, refresh_expires_in: 5_184_000 }.to_json
            else
              { error: "invalid_grant", error_description: "bad code" }.to_json
            end
    )
    stub_request(:get, "https://api.airtable.com/v0/meta/whoami")
      .to_return(status: 200, body: { id: "usrFictional", email: "organiser@example.com" }.to_json)
    stub_request(:get, "https://api.airtable.com/v0/meta/bases")
      .to_return(status: 200, body: { bases: [ { id: "appTest", name: "Fictional Base" } ] }.to_json)
  end

  describe "POST /admin/:slug/integrations/airtable/connection" do
    it "sends the organiser to Airtable with PKCE" do
      params = start_connect

      expect(response.location).to start_with("https://airtable.com/oauth2/v1/authorize?")
      expect(params["redirect_uri"]).to eq(admin_airtable_oauth_callback_url)
      expect(params["code_challenge_method"]).to eq("S256")
      expect(params["state"]).to be_present
    end

    it "says so when the server has no OAuth credentials" do
      allow(Rails.application.credentials).to receive(:dig).with(:airtable, :oauth_client_id).and_return(nil)

      post admin_event_airtable_connection_path(event)

      expect(response).to redirect_to(admin_event_integrations_path(event))
      expect(flash[:alert]).to include("isn't set up")
    end
  end

  describe "GET /admin/airtable/oauth/callback" do
    it "saves the connection, drops the pasted token, and starts a sync" do
      stub_airtable
      state = start_connect["state"]
      event.pause_airtable_sync!("HTTP 401")

      expect {
        get admin_airtable_oauth_callback_path, params: { code: "fictional-code", state: state }
      }.to have_enqueued_job(AirtableJobs::SyncAllJob)

      event.reload
      connection = event.airtable_connection
      expect(connection.access_token).to eq("fictional-access")
      expect(connection.airtable_email).to eq("organiser@example.com")
      expect(connection.base_granted?("appTest")).to be(true)
      expect(connection.connected_by).to eq(admin)
      expect(event.airtable_api_key).to be_nil
      # The old Sync API table can't take records-API writes.
      expect(event.airtable_sync_source_id).to be_nil
      expect(event.airtable_sync_table_id).to be_nil
      expect(event.airtable_base_id).to eq("appTest")
      expect(event.airtable_sync_paused?).to be(false)
      expect(event.airtable_config_updated_by).to eq(admin)
      expect(flash[:notice]).to eq("Airtable connected as organiser@example.com. Sync started.")

      log = AuditLog.find_by!(action: "connect_airtable")
      expect(log.event).to eq(event)
      expect(log.changed_fields.to_s).not_to include("fictional-access")
    end

    it "syncs through the records API with the connection's token" do
      stub_airtable
      state = start_connect["state"]
      get admin_airtable_oauth_callback_path, params: { code: "fictional-code", state: state }
      create(:participant_event, event: event)
      allow_any_instance_of(Airtable::RecordsSync).to receive(:sleep)
      auth = { "Authorization" => "Bearer fictional-access" }
      stub_request(:get, "https://api.airtable.com/v0/meta/bases/appTest/tables").with(headers: auth)
        .to_return(status: 200, body: { tables: [] }.to_json)
      stub_request(:post, "https://api.airtable.com/v0/meta/bases/appTest/tables").with(headers: auth)
        .to_return(status: 200, body: { id: "tblOurs", name: "Attend Participants",
          fields: Airtable::SyncService::SYNC_COLUMNS.map { |c| { name: c } } }.to_json)
      stub_request(:get, %r{/v0/appTest/tblOurs}).with(headers: auth).to_return(status: 200, body: { records: [] }.to_json)
      upsert = stub_request(:patch, "https://api.airtable.com/v0/appTest/tblOurs").with(headers: auth)
        .to_return(status: 200, body: { records: [] }.to_json)

      AirtableJobs::SyncAllJob.perform_now

      expect(upsert).to have_been_requested
      expect(event.reload.airtable_synced_at).to be_present
      expect(event.airtable_sync_paused?).to be(false)
    end

    it "picks the base automatically when only one was granted" do
      stub_airtable
      event.update!(airtable_sync_endpoint_url: "")
      state = start_connect["state"]

      get admin_airtable_oauth_callback_path, params: { code: "fictional-code", state: state }

      expect(event.reload.airtable_base_id).to eq("appTest")
      expect(event.airtable_sync_configured?).to be(true)
    end

    it "rejects a callback whose state doesn't match" do
      stub_airtable
      start_connect

      get admin_airtable_oauth_callback_path, params: { code: "fictional-code", state: "forged" }

      expect(event.reload.airtable_connection).to be_nil
      expect(flash[:alert]).to include("expired")
    end

    it "reports a refused consent screen" do
      state = start_connect["state"]

      get admin_airtable_oauth_callback_path, params: { error: "access_denied", error_description: "User denied access", state: state }

      expect(event.reload.airtable_connection).to be_nil
      expect(flash[:alert]).to eq("Airtable wasn't connected: User denied access")
    end

    it "explains a failed code exchange instead of raising" do
      stub_airtable(token_status: 400)
      state = start_connect["state"]

      get admin_airtable_oauth_callback_path, params: { code: "fictional-code", state: state }

      expect(event.reload.airtable_connection).to be_nil
      expect(event.airtable_api_key).to eq("patFictionalLegacy")
      expect(flash[:alert]).to include("couldn't connect Airtable")
    end
  end

  describe "DELETE /admin/:slug/integrations/airtable/connection" do
    it "removes the connection and logs it" do
      event.create_airtable_connection!(
        access_token: "fictional-access", refresh_token: "fictional-refresh",
        access_token_expires_at: 1.hour.from_now, refresh_token_expires_at: 60.days.from_now
      )

      delete admin_event_airtable_connection_path(event)

      expect(event.reload.airtable_connection).to be_nil
      expect(AuditLog.where(action: "disconnect_airtable", event: event)).to exist
    end
  end
end
