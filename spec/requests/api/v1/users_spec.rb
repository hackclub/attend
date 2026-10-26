require "rails_helper"

RSpec.describe "Api::V1::Users", type: :request do
  let(:admin) { create(:user, global_role: :global_admin) }
  let(:headers) { { "Authorization" => "Bearer #{GlobalApiToken.generate_for(admin, name: "support-bot").token}" } }
  let(:organizer) { create(:user, oidc_claims: { "slack_id" => "U0TESTORG1" }) }

  def json
    JSON.parse(response.body)
  end

  describe "GET /api/v1/users/lookup" do
    # Links go to APP_HOST like every other URL Attend hands out, not to
    # whatever host the bot happened to call.
    around do |example|
      original = ENV["APP_HOST"]
      ENV["APP_HOST"] = "attend.example.test"
      example.run
    ensure
      ENV["APP_HOST"] = original
    end

    it "lists the events someone runs, with a link to each dashboard" do
      event = create(:event, name: "Pancake Hack")
      create(:event_role_assignment, user: organizer, event: event, role: "event_admin")

      get "/api/v1/users/lookup", params: { slack_id: "u0testorg1" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(json["user"]["id"]).to eq(organizer.id)
      entry = json["events"].sole
      expect(entry).to include("name" => "Pancake Hack", "slug" => event.slug)
      expect(entry["dashboard_url"]).to eq("https://attend.example.test/admin/#{event.slug}")
    end

    it "counts series membership and leaves out ended events and non-admin roles" do
      series = create(:event_series)
      create(:series_role_assignment, user: organizer, event_series: series)
      via_series = create(:event, event_series: series, starts_at: 1.week.from_now)
      ended = create(:event, starts_at: 3.weeks.ago, ends_at: 2.weeks.ago)
      create(:event_role_assignment, user: organizer, event: ended, role: "event_admin")
      create(:event_role_assignment, user: organizer, event: create(:event), role: "read_only")
      via_role = create(:event, starts_at: 2.days.from_now)
      create(:event_role_assignment, user: organizer, event: via_role, role: "ops")

      get "/api/v1/users/lookup", params: { slack_id: "U0TESTORG1" }, headers: headers

      expect(json["events"].map { |event| event["slug"] }).to eq([ via_role.slug, via_series.slug ])
    end

    # Anyone can type any ID into their profile; only Hack Club Auth's counts.
    it "ignores the profile Slack ID override" do
      impostor = create(:user, slack_user_id: "U0TESTORG2")
      create(:event_role_assignment, user: impostor, event: create(:event), role: "event_admin")

      get "/api/v1/users/lookup", params: { slack_id: "U0TESTORG2" }, headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "is reachable by a token scoped to support:read, which can't reach anything else" do
      create(:event_role_assignment, user: organizer, event: create(:event), role: "event_admin")
      scoped = { "Authorization" => "Bearer #{GlobalApiToken.generate_for(admin, scopes: [ "support:read" ]).token}" }

      get "/api/v1/users/lookup", params: { slack_id: "U0TESTORG1" }, headers: scoped
      expect(response).to have_http_status(:ok)

      get "/api/v1/events", headers: scoped
      expect(response).to have_http_status(:forbidden)
    end

    # Nothing makes a verified Slack ID unique, so two accounts can carry
    # one. Answering for either would be a guess.
    it "refuses to pick between two accounts with the same Slack ID" do
      twin = create(:user, oidc_claims: { "slack_id" => "U0TESTORG1" })
      [ organizer, twin ].each do |user|
        create(:event_role_assignment, user: user, event: create(:event), role: "event_admin")
      end

      get "/api/v1/users/lookup", params: { slack_id: "U0TESTORG1" }, headers: headers

      expect(response).to have_http_status(:conflict)
      expect(json).to eq("error" => "More than one user matches that Slack ID")
    end

    it "requires a slack_id" do
      get "/api/v1/users/lookup", headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "is closed to anyone but a global admin" do
      create(:event_role_assignment, user: organizer, event: create(:event), role: "event_admin")

      get "/api/v1/users/lookup", params: { slack_id: "U0TESTORG1" },
        headers: { "Authorization" => "Bearer #{MobileToken.generate_for(organizer).token}" }

      expect(response).to have_http_status(:forbidden)
      expect(json).to eq("error" => "Only global admins can look up users")
    end
  end
end
