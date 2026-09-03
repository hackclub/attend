require "rails_helper"

RSpec.describe "Api::V1::Series", type: :request do
  let(:series) { create(:event_series, name: "Sunbeam", slug: "sunbeam-api") }
  let(:other_series) { create(:event_series, name: "Moonbeam", slug: "moonbeam-api") }

  let(:owner) do
    User.create!(email: "owner-series-api@example.com", name: "Owner").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
    end
  end
  let(:outsider) { User.create!(email: "outsider-series-api@example.com", name: "Outsider") }

  let(:series_key) { SeriesApiToken.generate_for(series, user: owner, name: "ops").token }
  let(:series_headers) { { "Authorization" => "Bearer #{series_key}" } }

  def user_headers(user)
    { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" }
  end

  describe "GET /series" do
    it "returns only the key's own series, so a client can discover it from the key alone" do
      other_series

      get "/api/v1/series", headers: series_headers

      expect(response).to have_http_status(:ok)
      slugs = JSON.parse(response.body)["series"].map { |s| s["slug"] }
      expect(slugs).to eq([ series.slug ])
    end

    it "returns the caller's series for a user token" do
      other_series

      get "/api/v1/series", headers: user_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["series"].map { |s| s["slug"] }).to eq([ series.slug ])
    end

    it "returns nothing for an event API key" do
      event = create(:event, event_series: series)
      key = EventApiToken.generate_for(event, user: owner, name: "event-key").token

      get "/api/v1/series", headers: { "Authorization" => "Bearer #{key}" }

      expect(JSON.parse(response.body)["series"]).to be_empty
    end

    it "rejects a request with no credentials" do
      get "/api/v1/series"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /series/:id" do
    it "resolves `current` to the series the key belongs to" do
      create(:event, event_series: series, name: "Sunbeam One")

      get "/api/v1/series/current", headers: series_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)["series"]
      expect(body["slug"]).to eq(series.slug)
      expect(body["events"].map { |e| e["name"] }).to eq([ "Sunbeam One" ])
    end

    it "accepts the slug or the id" do
      get "/api/v1/series/#{series.slug}", headers: series_headers
      expect(response).to have_http_status(:ok)

      get "/api/v1/series/#{series.id}", headers: series_headers
      expect(response).to have_http_status(:ok)
    end

    it "refuses another series to a series key" do
      get "/api/v1/series/#{other_series.slug}", headers: series_headers

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to match(/not valid for this series/)
    end

    it "rejects `current` when the caller is not a series key" do
      get "/api/v1/series/current", headers: user_headers(owner)

      expect(response).to have_http_status(:bad_request)
    end

    it "refuses a user who is not a member of the series" do
      get "/api/v1/series/#{series.slug}", headers: user_headers(outsider)

      expect(response).to have_http_status(:forbidden)
    end

    it "404s an unknown series" do
      get "/api/v1/series/does-not-exist", headers: series_headers

      expect(response).to have_http_status(:not_found)
    end

    it "stops working once the key is revoked" do
      token = SeriesApiToken.generate_for(series, user: owner, name: "short-lived")
      headers = { "Authorization" => "Bearer #{token.token}" }

      get "/api/v1/series/current", headers: headers
      expect(response).to have_http_status(:ok)

      token.revoke!

      get "/api/v1/series/current", headers: headers
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
