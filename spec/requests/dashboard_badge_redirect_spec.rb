require "rails_helper"

RSpec.describe "Dashboard badge link settings", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user, slack_user_id: "U01ABCDEF") }
  let!(:participant) { create(:participant, user: user) }

  before { sign_in user }

  describe "GET /dashboard/profile" do
    it "shows the badge link and its current target" do
      create(:badge_redirect, slack_id: "U01ABCDEF", url: "https://example.com/grace", user: user)

      get dashboard_profile_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Badge link")
      expect(response.body).to include("https://badge.hackclub.com/t/U01ABCDEF")
      expect(response.body).to include("https://example.com/grace")
    end

    it "offers the form before anything has been set" do
      get dashboard_profile_path

      expect(response.body).to include("https://badge.hackclub.com/t/U01ABCDEF")
      expect(response.body).to include("Not set")
    end

    it "asks for a Slack link instead when the account has no Slack ID" do
      user.update!(slack_user_id: nil)

      get dashboard_profile_path

      expect(response.body).to include("Badge links are keyed to your Slack account")
    end
  end

  describe "PATCH /dashboard/badge_redirect" do
    it "creates the redirect on first save" do
      patch dashboard_badge_redirect_path, params: { badge_redirect: { url: "example.com/grace" } }

      expect(response).to redirect_to(dashboard_profile_path(anchor: "badge-link"))
      badge_redirect = BadgeRedirect.for_slack_id("U01ABCDEF")
      expect(badge_redirect.url).to eq("https://example.com/grace")
      expect(badge_redirect.user).to eq(user)
    end

    it "updates an existing redirect, including one imported without an owner" do
      badge_redirect = create(:badge_redirect, slack_id: "U01ABCDEF", url: "https://old.example.com", user: nil)

      patch dashboard_badge_redirect_path, params: { badge_redirect: { url: "https://new.example.com" } }

      expect(badge_redirect.reload.url).to eq("https://new.example.com")
      expect(badge_redirect.user).to eq(user)
    end

    it "clears the link when the field is emptied" do
      badge_redirect = create(:badge_redirect, slack_id: "U01ABCDEF", url: "https://old.example.com")

      patch dashboard_badge_redirect_path, params: { badge_redirect: { url: "" } }

      expect(badge_redirect.reload.url).to be_nil
      expect(flash[:notice]).to eq("Badge link cleared.")
    end

    it "refuses a link that isn't a web address" do
      patch dashboard_badge_redirect_path, params: { badge_redirect: { url: "javascript:alert(1)" } }

      expect(flash[:alert]).to be_present
      expect(BadgeRedirect.for_slack_id("U01ABCDEF")).to be_nil
    end

    it "refuses to save for an account with no Slack ID" do
      user.update!(slack_user_id: nil)

      patch dashboard_badge_redirect_path, params: { badge_redirect: { url: "https://example.com" } }

      expect(flash[:alert]).to include("Connect your Slack account")
      expect(BadgeRedirect.count).to eq(0)
    end

    it "cannot touch someone else's badge" do
      other = create(:badge_redirect, slack_id: "U0OTHER", url: "https://theirs.example.com")

      patch dashboard_badge_redirect_path, params: { badge_redirect: { url: "https://mine.example.com" } }

      expect(other.reload.url).to eq("https://theirs.example.com")
    end
  end
end
