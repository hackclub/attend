require "rails_helper"

RSpec.describe "Admin::Integrations", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-integrations@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) do
    create(:event,
      airtable_sync_source_id: "syncabc",
      airtable_sync_table_id: "tbltest",
      airtable_api_key: "key-test",
      config: { "airtable_base_id" => "app-test" })
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

    # The token list exists in both admin UIs, so pin it in each.
    { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
      context ui do
        before { admin.update!(admin_console_beta: console) }

        # Browsers drop a <form> nested inside another, so a button_to inside
        # the settings form silently submits the settings form instead.
        it "gives Sync Now its own form rather than nesting it in the settings form" do
          get admin_event_integrations_path(event)

          button = Nokogiri::HTML5(response.body).xpath("//button[normalize-space()='Sync Now']").first
          expect(button).to be_present
          form = button["form"].present? ? Nokogiri::HTML5(response.body).at_css("form##{button['form']}") : button.ancestors("form").first
          expect(form["action"]).to eq(admin_event_trigger_airtable_sync_path(event))
        end

        it "lists the event's active API tokens" do
          EventApiToken.generate_for(event, user: admin, name: "fictional-widget-sync")

          get admin_event_integrations_path(event)

          expect(response.body).to include("admin-integrations@fictional-widget-sync")
          expect(response.body).not_to include("No API tokens yet")
        end

        it "leaves revoked tokens and other events' tokens out of the list" do
          EventApiToken.generate_for(event, user: admin, name: "fictional-retired-sync").revoke!
          EventApiToken.generate_for(create(:event), user: admin, name: "fictional-elsewhere-sync")

          get admin_event_integrations_path(event)

          expect(response.body).not_to include("fictional-retired-sync")
          expect(response.body).not_to include("fictional-elsewhere-sync")
          expect(response.body).to include("No API tokens yet")
        end

        it "shows the empty state when the event has no API tokens" do
          get admin_event_integrations_path(event)

          expect(response.body).to include("No API tokens yet")
        end
      end
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

    it "fills the base, table and sync ids from a pasted sync endpoint URL" do
      expect {
        patch admin_event_integrations_path(event), params: {
          event: { airtable_sync_endpoint_url: " https://api.airtable.com/v0/appNew/tblNew/sync/sncNew \n" }
        }
      }.to have_enqueued_job(AirtableJobs::SyncAllJob)

      event.reload
      expect([ event.airtable_base_id, event.airtable_sync_table_id, event.airtable_sync_source_id ])
        .to eq(%w[appNew tblNew sncNew])
    end

    it "rejects a URL that isn't a sync endpoint and keeps the old settings" do
      patch admin_event_integrations_path(event), params: {
        event: { airtable_sync_endpoint_url: "https://airtable.com/appNew/tblNew/viwNew" }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("doesn&#39;t look like an Airtable sync endpoint")
      expect(event.reload.airtable_base_id).to eq("app-test")
    end

    it "keeps the saved token when the token field is left blank" do
      patch admin_event_integrations_path(event), params: {
        event: { airtable_api_key: "", slack_channel_id: "C123456" }
      }

      expect(event.reload.airtable_api_key).to eq("key-test")
    end

    it "never echoes the saved token back into the page" do
      get admin_event_integrations_path(event)

      expect(response.body).not_to include("key-test")
    end

    it "keeps the token out of the audit log and the event's versions" do
      patch admin_event_integrations_path(event), params: {
        event: { airtable_api_key: "patFictionalRotated" }
      }

      expect(AuditLog.where(event: event).pluck(:changed_fields).to_s).not_to include("patFictionalRotated")
      expect(PaperTrail::Version.where(item_type: "Event", item_id: event.id).pluck(:object, :object_changes).to_s)
        .not_to include("patFictionalRotated")
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

  describe "POST /admin/:slug/integrations/vote_event" do
    let(:vote_client) { instance_double(Vote::Client, configured?: true) }

    before do
      allow(Vote::Client).to receive(:new).and_return(vote_client)
      allow(vote_client).to receive(:find_event).with(event.slug).and_return(
        "id" => "vote-evt-1",
        "slug" => event.slug,
        "adminUrl" => "https://vote.hackclub.com/admin/vote-evt-1",
        "galleryUrl" => "https://vote.hackclub.com/vote-evt-1"
      )

      # Consume Devise trackable's sign-in columns on a throwaway request so the
      # event, not the user, is the changed record log_admin_action picks up.
      get admin_event_integrations_path(event)
    end

    it "audit-logs the linkage" do
      expect {
        post admin_event_create_vote_event_path(event)
      }.to change(AuditLog, :count).by(1)

      log = AuditLog.order(:created_at).last
      expect(log.action).to eq("create_vote_event")
      expect(log.record).to eq(event)
      expect(log.actor).to eq(admin)
      expect(log.event).to eq(event)
      expect(event.reload.vote_event_id).to eq("vote-evt-1")
    end
  end
end
