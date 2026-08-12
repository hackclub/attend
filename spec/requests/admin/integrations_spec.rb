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

    it "says the sync is paused rather than silently showing nothing" do
      event.pause_airtable_sync!("HTTP 403: INVALID_PERMISSIONS")

      get admin_event_integrations_path(event)

      expect(response.body).to include("Paused")
      expect(response.body).to include("Sync paused after a failure")
      expect(response.body).to include("Resume &amp; Sync Now")
    end

    it "names the person who was emailed about the pause" do
      saver = create(:user, name: "Sam Rivers")
      event.update!(airtable_config_updated_by: saver)
      event.pause_airtable_sync!("HTTP 403: INVALID_PERMISSIONS")

      get admin_event_integrations_path(event)

      expect(response.body).to include("Sam Rivers was emailed")
    end

    it "does not call a paused sync stale" do
      event.update_columns(airtable_synced_at: 3.hours.ago)
      event.pause_airtable_sync!("HTTP 403: INVALID_PERMISSIONS")

      get admin_event_integrations_path(event)

      expect(response.body).not_to include("Stale")
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

    it "records who saved the Airtable settings, so they can be emailed on failure" do
      patch admin_event_integrations_path(event), params: {
        event: { airtable_api_key: "key-rotated" }
      }

      expect(event.reload.airtable_config_updated_by).to eq(admin)
    end

    it "leaves the recorded owner alone when only non-Airtable settings change" do
      previous = create(:user)
      event.update!(airtable_config_updated_by: previous)

      patch admin_event_integrations_path(event), params: {
        event: { slack_channel_id: "C123456" }
      }

      expect(event.reload.airtable_config_updated_by).to eq(previous)
    end

    it "resumes a paused sync when the settings are saved again" do
      event.pause_airtable_sync!("HTTP 403: INVALID_PERMISSIONS")

      patch admin_event_integrations_path(event), params: {
        event: { airtable_sync_source_id: "syncfixed" }
      }

      event.reload
      expect(event.airtable_sync_paused?).to be(false)
      expect(event.airtable_sync_error).to be_nil
    end
  end

  describe "POST /admin/:slug/integrations/airtable_sync" do
    include ActiveJob::TestHelper

    it "resumes a paused sync so the button isn't a no-op" do
      event.pause_airtable_sync!("HTTP 403: INVALID_PERMISSIONS")

      expect {
        post admin_event_trigger_airtable_sync_path(event)
      }.to have_enqueued_job(AirtableJobs::SyncAllJob)

      expect(event.reload.airtable_sync_paused?).to be(false)
      expect(flash[:notice]).to eq("Airtable sync resumed and triggered. It will complete shortly.")
    end

    it "just triggers a sync when nothing is paused" do
      expect {
        post admin_event_trigger_airtable_sync_path(event)
      }.to have_enqueued_job(AirtableJobs::SyncAllJob)

      expect(flash[:notice]).to eq("Airtable sync triggered. It will complete shortly.")
    end
  end
end
