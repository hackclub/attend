require "rails_helper"

RSpec.describe "Admin::Bans", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:global_admin) { User.create!(email: "ga-bans@example.com", name: "Global Admin", global_role: "global_admin", admin_console_beta: console) }

  before { sign_in global_admin }

  shared_examples "the ban list" do
    it "searches by email, Slack ID and reason" do
      create(:ban, email: "alpha@example.com", reason: "Alpha reason")
      create(:ban, email: "bravo@example.com", reason: "Bravo reason")
      slack_ban = Ban.new(reason: "Slack only")
      slack_ban.ban_slack_ids.build(slack_id: "U0123456789")
      slack_ban.save!

      get admin_bans_path, params: { search: "alpha" }
      expect(response.body).to include("alpha@example.com")
      expect(response.body).not_to include("bravo@example.com")

      get admin_bans_path, params: { search: "Bravo reason" }
      expect(response.body).to include("bravo@example.com")
      expect(response.body).not_to include("alpha@example.com")

      get admin_bans_path, params: { search: "u0123456789" }
      expect(response.body).to include("U0123456789")
      expect(response.body).not_to include("alpha@example.com")
    end

    it "escapes LIKE wildcards in the search term" do
      create(:ban, email: "percent@example.com")

      get admin_bans_path, params: { search: "%" }

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("percent@example.com")
    end

    it "filters by status" do
      create(:ban, email: "active@example.com")
      create(:ban, :expired, email: "expired@example.com")
      create(:ban, email: "revoked@example.com").revoke!(by: global_admin)

      get admin_bans_path, params: { status: "active" }
      expect(response.body).to include("active@example.com")
      expect(response.body).not_to include("expired@example.com", "revoked@example.com")

      get admin_bans_path, params: { status: "expired" }
      expect(response.body).to include("expired@example.com")
      expect(response.body).not_to include("active@example.com", "revoked@example.com")

      get admin_bans_path, params: { status: "revoked" }
      expect(response.body).to include("revoked@example.com")
      expect(response.body).not_to include("active@example.com", "expired@example.com")

      get admin_bans_path, params: { status: "bogus" }
      expect(response.body).to include("active@example.com", "expired@example.com", "revoked@example.com")
    end

    it "paginates and clamps out-of-range pages" do
      stub_const("Admin::BansController::PER_PAGE", 2)
      3.times { |i| create(:ban, email: "page#{i}@example.com", created_at: i.hours.ago) }

      get admin_bans_path
      expect(response.body).to include("page0@example.com", "page1@example.com")
      expect(response.body).not_to include("page2@example.com")
      expect(response.body).to include("Showing 1 to 2 of 3 bans")
      expect(response.body).to include("Next page")

      get admin_bans_path, params: { page: 2 }
      expect(response.body).to include("page2@example.com")
      expect(response.body).not_to include("page0@example.com")
      expect(response.body).to include("Previous page")

      get admin_bans_path, params: { page: 99 }
      expect(response.body).to include("page2@example.com")
    end

    it "keeps the search and status in pagination links" do
      stub_const("Admin::BansController::PER_PAGE", 1)
      2.times { |i| create(:ban, email: "keep#{i}@example.com", reason: "shared") }

      get admin_bans_path, params: { search: "shared", status: "active" }

      expect(response.body).to include("search=shared")
      expect(response.body).to include("status=active")
      expect(response.body).to include("page=2")
    end
  end

  describe "GET index (console)" do
    let(:console) { true }

    include_examples "the ban list"
  end

  describe "GET index (legacy)" do
    let(:console) { false }

    include_examples "the ban list"
  end
end
