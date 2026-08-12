require "rails_helper"

RSpec.describe "Admin::Integrations", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-integrations@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) do
    create(:event,
      airtable_sync_source_id: "syncabc",
      airtable_sync_table_id: "tbltest",
      config: { "airtable_api_key" => "key-test", "airtable_base_id" => "app-test" })
  end

  before { sign_in admin }

  describe "GET /admin/:slug/integrations" do
    it "shows the last sync error when the sync is failing" do
      event.update_columns(airtable_sync_error: "HTTP 404: NOT_FOUND", airtable_sync_error_at: 5.minutes.ago)

      get admin_event_integrations_path(event)

      expect(response.body).to include("Last sync attempt failed")
      expect(response.body).to include("HTTP 404: NOT_FOUND")
    end

    it "shows no error banner when the sync is healthy" do
      event.update_columns(airtable_synced_at: 2.minutes.ago)

      get admin_event_integrations_path(event)

      expect(response.body).to include("Last synced")
      expect(response.body).not_to include("Last sync attempt failed")
    end
  end

  describe "PATCH /admin/:slug/integrations" do
    include ActiveJob::TestHelper

    it "starts a sync immediately when Airtable credentials change" do
      expect {
        patch admin_event_integrations_path(event), params: {
          event: { airtable_api_key: "key-rotated" }
        }
      }.to have_enqueued_job(AirtableJobs::SyncAllJob)

      expect(flash[:notice]).to eq("Integration settings updated. Airtable sync started.")
    end

    it "starts a sync when a sync id changes" do
      expect {
        patch admin_event_integrations_path(event), params: {
          event: { airtable_sync_source_id: "syncnew" }
        }
      }.to have_enqueued_job(AirtableJobs::SyncAllJob)
    end

    it "does not start a sync when Airtable settings are unchanged" do
      expect {
        patch admin_event_integrations_path(event), params: {
          event: { airtable_api_key: "key-test", slack_channel_id: "C123456" }
        }
      }.not_to have_enqueued_job(AirtableJobs::SyncAllJob)

      expect(flash[:notice]).to eq("Integration settings updated.")
    end

    it "does not start a sync while the configuration is still incomplete" do
      event.update_columns(airtable_sync_table_id: nil)

      expect {
        patch admin_event_integrations_path(event), params: {
          event: { airtable_api_key: "key-partial" }
        }
      }.not_to have_enqueued_job(AirtableJobs::SyncAllJob)

      expect(flash[:notice]).to eq("Integration settings updated.")
    end
  end
end
