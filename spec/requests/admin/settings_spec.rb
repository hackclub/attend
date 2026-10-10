require "rails_helper"

RSpec.describe "Admin::Settings", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:global_admin) { User.create!(email: "ga-settings@example.com", name: "Global Admin", global_role: "global_admin") }
  let(:event_admin) do
    User.create!(email: "ea-settings@example.com", name: "Event Admin").tap do |user|
      EventRoleAssignment.create!(user: user, event: event, role: "event_admin")
    end
  end

  describe "support SMS notification settings" do
    it "renders the settings page with the notification card" do
      Setting.support_sms_notification_numbers = [ "+14155551234" ]
      sign_in global_admin

      get admin_settings_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Support Inbox Notifications")
      expect(response.body).to include("+14155551234")
    end

    it "denies non-global-admins" do
      sign_in event_admin

      post update_support_sms_numbers_admin_settings_path, params: { support_sms_notification_numbers: "+14155551234" }

      expect(response).to redirect_to(admin_root_path)
      expect(Setting.support_sms_notification_number_list).to be_empty
    end

    it "saves a newline/comma-separated list of valid numbers" do
      sign_in global_admin

      post update_support_sms_numbers_admin_settings_path,
        params: { support_sms_notification_numbers: "+14155551234\n+44 7911 123456, +14155551234" }

      expect(Setting.support_sms_notification_number_list).to eq([ "+14155551234", "+447911123456" ])
    end

    it "rejects invalid numbers without saving" do
      sign_in global_admin

      post update_support_sms_numbers_admin_settings_path,
        params: { support_sms_notification_numbers: "+14155551234\nnot-a-number5" }

      expect(flash[:alert]).to include("Invalid phone number")
      expect(Setting.support_sms_notification_number_list).to be_empty
    end

    it "refuses to enable notifications with no numbers configured" do
      sign_in global_admin

      post toggle_support_sms_admin_settings_path

      expect(flash[:alert]).to be_present
      expect(Setting.support_sms_notifications_enabled?).to be(false)
    end

    it "toggles notifications on once numbers exist" do
      Setting.support_sms_notification_numbers = [ "+14155551234" ]
      sign_in global_admin

      post toggle_support_sms_admin_settings_path

      expect(Setting.support_sms_notifications_enabled?).to be(true)
    end
  end

  describe "admin help Slack channel" do
    include ActiveJob::TestHelper

    it "shows the channel and how many people would be synced" do
      Setting.admin_help_slack_channel_id = "CHELP"
      event_admin
      sign_in global_admin

      get admin_settings_path

      expect(response.body).to include("Admin Help Slack Channel")
      expect(response.body).to include("CHELP")
      expect(response.body).to include("2 eligible people") # the event admin plus the signed-in global admin
    end

    it "saves the channel ID and rejects junk" do
      sign_in global_admin

      post update_admin_help_slack_channel_admin_settings_path, params: { admin_help_slack_channel_id: " CHELP123 " }
      expect(Setting.admin_help_slack_channel_id).to eq("CHELP123")

      post update_admin_help_slack_channel_admin_settings_path, params: { admin_help_slack_channel_id: "#attend-help" }
      expect(flash[:alert]).to be_present
      expect(Setting.admin_help_slack_channel_id).to eq("CHELP123")
    end

    it "enqueues a full sync" do
      Setting.admin_help_slack_channel_id = "CHELP"
      sign_in global_admin

      expect {
        post sync_admin_help_slack_channel_admin_settings_path
      }.to have_enqueued_job(SyncAdminHelpSlackChannelJob).with(no_args)
    end

    it "denies non-global-admins" do
      Setting.admin_help_slack_channel_id = "CHELP"
      sign_in event_admin

      expect {
        post sync_admin_help_slack_channel_admin_settings_path
      }.not_to have_enqueued_job(SyncAdminHelpSlackChannelJob)
      expect(response).to redirect_to(admin_root_path)
    end
  end
end
