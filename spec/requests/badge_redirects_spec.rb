require "rails_helper"

RSpec.describe "Badge redirects", type: :request do
  let!(:badge_redirect) { create(:badge_redirect, slack_id: "U01ABCDEF", url: "https://example.com/grace") }

  describe "on the badge host" do
    before { host! BadgeRedirect.badge_host }

    it "sends the scanner to the link its owner set" do
      get "/t/U01ABCDEF"

      expect(response).to redirect_to("https://example.com/grace")
    end

    it "matches regardless of the case the QR encodes" do
      get "/t/u01abcdef"

      expect(response).to redirect_to("https://example.com/grace")
    end

    it "explains itself instead of erroring when nobody has claimed the badge" do
      get "/t/U0NOBODY"

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("doesn't point anywhere yet")
      expect(response.body).to include("U0NOBODY")
    end

    it "explains itself when the owner has cleared their link" do
      badge_redirect.update!(url: nil)

      get "/t/U01ABCDEF"

      expect(response).to have_http_status(:not_found)
    end

    it "answers browsers Attend itself turns away, since anything can scan a badge" do
      get "/t/U01ABCDEF", headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh) Safari/605 Version/10.0" }

      expect(response).to redirect_to("https://example.com/grace")
    end

    it "sends every other page back to Attend, where the links are managed" do
      get "/dashboard/profile"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to eq(
        AttendUrls.attend_url(dashboard_profile_path(anchor: "badge-link"))
      )
    end

    it "bounces the root too" do
      get "/"

      expect(response).to have_http_status(:moved_permanently)
    end

    it "does not expose the MCP engine on the badge domain" do
      get "/mcp"

      expect(response).to have_http_status(:moved_permanently)
    end

    it "routes a write to the badge domain away from Attend's controllers" do
      post "/dashboard/badge_redirect", params: { badge_redirect: { url: "https://evil.example.com" } }

      expect(response).to have_http_status(:moved_permanently)
      expect(badge_redirect.reload.url).to eq("https://example.com/grace")
    end

    it "refuses it outright once forgery protection is on, as it is in production" do
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true

      post "/dashboard/badge_redirect", params: { badge_redirect: { url: "https://evil.example.com" } }

      expect(response).to have_http_status(:unprocessable_content)
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    it "still answers the health check" do
      get "/up"

      expect(response).to have_http_status(:ok)
    end
  end

  describe "on Attend's own host" do
    it "does not serve redirects, so the open redirect stays off the sign-in domain" do
      get "/t/U01ABCDEF"

      expect(response).to have_http_status(:not_found)
    end
  end
end
