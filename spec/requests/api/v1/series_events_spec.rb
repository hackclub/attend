require "rails_helper"

RSpec.describe "Api::V1::Series::Events", type: :request do
  let(:series) { create(:event_series, name: "Sunbeam", slug: "sunbeam-events-api") }
  let(:other_series) { create(:event_series, name: "Moonbeam", slug: "moonbeam-events-api") }

  let(:owner) do
    User.create!(email: "owner-series-events@example.com", name: "Owner").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
    end
  end
  let(:global_admin) do
    User.create!(email: "ga-series-events@example.com", name: "Global Admin", global_role: "global_admin")
  end

  let(:series_key) { SeriesApiToken.generate_for(series, user: owner, name: "ops").token }
  let(:series_headers) { { "Authorization" => "Bearer #{series_key}" } }

  def user_headers(user)
    { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" }
  end

  # Saving an address geocodes it (Event#geocode_location), which the setup
  # wizard triggers just the same. The Series API doesn't own that behaviour,
  # so it only needs to not blow up on it.
  before do
    stub_request(:get, /geocoder\.hackclub\.com/).to_return(
      status: 200,
      body: { lat: 60.1611, lng: 24.8918, formatted_address: "Helsinki, Finland" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def valid_attributes(overrides = {})
    {
      name: "Sunbeam Summer",
      support_email: "sunbeam@hackclub.com"
    }.merge(overrides)
  end

  describe "POST /series/:series_id/events" do
    it "creates the event in the key's own series without being told which series" do
      post "/api/v1/series/current/events", params: { event: valid_attributes }, headers: series_headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)["event"]
      expect(body["name"]).to eq("Sunbeam Summer")
      expect(body["slug"]).to eq("sunbeam-summer")
      expect(body["series"]["slug"]).to eq(series.slug)
      expect(Event.find(body["id"]).event_series_id).to eq(series.id)
    end

    it "accepts the whole web setup surface — schedule, location, and module toggles — in one call" do
      post "/api/v1/series/current/events",
        params: {
          event: valid_attributes(
            slug: "sunbeam-autumn",
            timezone: "Europe/Helsinki",
            starts_at: "2026-10-01T09:00:00Z",
            ends_at: "2026-10-04T17:00:00Z",
            registration_open_at: "2026-09-01T00:00:00Z",
            registration_close_at: "2026-09-20T00:00:00Z",
            venue_name: "Kaapelitehdas",
            location_city: "Helsinki",
            location_country: "Finland",
            location_address: "Tallberginkatu 1",
            travel_enabled: false,
            groups_enabled: true,
            nfc_badges_enabled: true
          )
        },
        headers: series_headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)["event"]
      expect(body["timezone"]).to eq("Europe/Helsinki")
      expect(body["venue_name"]).to eq("Kaapelitehdas")
      expect(body["starts_at"]).to be_present
      expect(body["modules"]).to include(
        "travel_enabled" => false,
        "groups_enabled" => true,
        "nfc_badges_enabled" => true
      )
    end

    # The web's new-event form marks exactly these two required.
    it "requires the same fields the web form requires" do
      post "/api/v1/series/current/events", params: { event: { slug: "no-name" } }, headers: series_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("name and support_email are required")
    end

    it "enforces the web's support email domain rule" do
      post "/api/v1/series/current/events",
        params: { event: valid_attributes(support_email: "team@example.com") },
        headers: series_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/@hackclub.com or @events.hackclub.com/)
    end

    it "surfaces model validation failures rather than a 500" do
      create(:event, slug: "taken-slug", event_series: series)

      post "/api/v1/series/current/events",
        params: { event: valid_attributes(slug: "taken-slug") },
        headers: series_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/Slug has already been taken/)
    end

    it "refuses to create an event in a series the key does not own" do
      post "/api/v1/series/#{other_series.slug}/events",
        params: { event: valid_attributes },
        headers: series_headers

      expect(response).to have_http_status(:forbidden)
      expect(other_series.events).to be_empty
    end

    it "rejects a body that names a different series rather than silently overriding it" do
      post "/api/v1/series/current/events",
        params: { event: valid_attributes(event_series_id: other_series.id) },
        headers: series_headers

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to match(/only create events in its own series/)
      expect(Event.where(name: "Sunbeam Summer")).to be_empty
    end

    it "tolerates a body that names the key's own series" do
      post "/api/v1/series/current/events",
        params: { event: valid_attributes(event_series_id: series.id) },
        headers: series_headers

      expect(response).to have_http_status(:created)
    end

    it "gives the key's owner an explicit event_admin role, as the web does for its creator" do
      post "/api/v1/series/current/events", params: { event: valid_attributes }, headers: series_headers

      event = Event.find(JSON.parse(response.body)["event"]["id"])
      expect(event.event_role_assignments.where(user: owner, role: "event_admin")).to exist
    end

    it "records an audit log attributed to the key" do
      expect {
        post "/api/v1/series/current/events", params: { event: valid_attributes }, headers: series_headers
      }.to change(AuditLog, :count).by(1)

      log = AuditLog.order(:created_at).last
      expect(log.action).to eq("record_create")
      expect(log.actor).to eq(owner)
      expect(log.metadata["source"]).to eq("series_api")
      expect(log.metadata["series_api_token_name"]).to eq("owner-series-events@ops")
    end

    describe "non-series credentials" do
      it "refuses an event API key" do
        event = create(:event, event_series: series)
        key = EventApiToken.generate_for(event, user: owner, name: "event-key").token

        post "/api/v1/series/#{series.slug}/events",
          params: { event: valid_attributes },
          headers: { "Authorization" => "Bearer #{key}" }

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to match(/cannot be used on the Series API/)
      end

      it "refuses a series owner's user token" do
        post "/api/v1/series/#{series.slug}/events",
          params: { event: valid_attributes },
          headers: user_headers(owner)

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to match(/requires a series API key/)
      end

      it "refuses a global API token" do
        key = GlobalApiToken.generate_for(global_admin, name: "superadmin").token

        post "/api/v1/series/#{series.slug}/events",
          params: { event: valid_attributes },
          headers: { "Authorization" => "Bearer #{key}" }

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to match(/requires a series API key/)
      end

      it "refuses an unauthenticated request" do
        post "/api/v1/series/#{series.slug}/events", params: { event: valid_attributes }

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "GET /series/:series_id/events" do
    it "lists only the series' own events" do
      create(:event, event_series: series, name: "In Series")
      create(:event, event_series: other_series, name: "Elsewhere")
      create(:event, name: "Standalone")

      get "/api/v1/series/current/events", headers: series_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["events"].map { |e| e["name"] }).to eq([ "In Series" ])
    end
  end

  describe "GET /series/:series_id/events/:id" do
    let!(:event) { create(:event, event_series: series, slug: "sunbeam-one") }

    it "accepts the event slug or id" do
      get "/api/v1/series/current/events/#{event.slug}", headers: series_headers
      expect(response).to have_http_status(:ok)

      get "/api/v1/series/current/events/#{event.id}", headers: series_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["event"]["modules"]).to be_present
    end

    it "404s an event in another series — from this key it does not exist" do
      elsewhere = create(:event, event_series: other_series, slug: "moonbeam-one")

      get "/api/v1/series/current/events/#{elsewhere.slug}", headers: series_headers

      expect(response).to have_http_status(:not_found)
    end

    it "404s a standalone event" do
      standalone = create(:event, slug: "standalone-one")

      get "/api/v1/series/current/events/#{standalone.slug}", headers: series_headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /series/:series_id/events/:id" do
    let!(:event) { create(:event, event_series: series, slug: "sunbeam-one", venue_name: "Old Hall") }

    it "updates any event in the series with the one key" do
      second = create(:event, event_series: series, slug: "sunbeam-two")

      patch "/api/v1/series/current/events/#{event.slug}",
        params: { event: { venue_name: "New Hall", groups_enabled: true } },
        headers: series_headers
      expect(response).to have_http_status(:ok)

      patch "/api/v1/series/current/events/#{second.slug}",
        params: { event: { venue_name: "Second Hall" } },
        headers: series_headers
      expect(response).to have_http_status(:ok)

      expect(event.reload.venue_name).to eq("New Hall")
      expect(event.groups_enabled?).to be(true)
      expect(second.reload.venue_name).to eq("Second Hall")
    end

    it "cannot move an event out of the series" do
      patch "/api/v1/series/current/events/#{event.slug}",
        params: { event: { event_series_id: other_series.id, venue_name: "Moved" } },
        headers: series_headers

      expect(response).to have_http_status(:ok)
      expect(event.reload.event_series_id).to eq(series.id)
      expect(event.venue_name).to eq("Moved")
    end

    it "refuses an event in another series" do
      elsewhere = create(:event, event_series: other_series, slug: "moonbeam-two", venue_name: "Theirs")

      patch "/api/v1/series/current/events/#{elsewhere.slug}",
        params: { event: { venue_name: "Hijacked" } },
        headers: series_headers

      expect(response).to have_http_status(:not_found)
      expect(elsewhere.reload.venue_name).to eq("Theirs")
    end

    it "returns validation errors" do
      patch "/api/v1/series/current/events/#{event.slug}",
        params: { event: { support_email: "team@example.com" } },
        headers: series_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(event.reload.support_email).not_to eq("team@example.com")
    end

    it "lets a series member's user token update too, as the web does" do
      patch "/api/v1/series/#{series.slug}/events/#{event.slug}",
        params: { event: { venue_name: "From the web" } },
        headers: user_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(event.reload.venue_name).to eq("From the web")
    end
  end

  # The whole point of the series key: it stands in for a per-event key on
  # every event in the series, so an organizer holds one credential.
  describe "acting as an event key across the series" do
    let!(:event) { create(:event, event_series: series) }

    it "reads the roster of any event in the series" do
      get "/api/v1/events/#{event.slug}/participants/roster", headers: series_headers

      expect(response).to have_http_status(:ok)
    end

    it "is refused on an event outside the series" do
      elsewhere = create(:event, event_series: other_series)

      get "/api/v1/events/#{elsewhere.slug}/participants/roster", headers: series_headers

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to match(/not valid for this event/)
    end

    it "is refused on a standalone event" do
      standalone = create(:event)

      get "/api/v1/events/#{standalone.slug}/participants/roster", headers: series_headers

      expect(response).to have_http_status(:forbidden)
    end

    it "still cannot read the full participant payload — that needs a person" do
      get "/api/v1/events/#{event.slug}/participants", headers: series_headers

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to match(/not authorized for this action/)
    end

    it "still cannot read or write notes" do
      participant_event = create(:participant_event, event: event)

      get "/api/v1/events/#{event.id}/participants/#{participant_event.id}/notes", headers: series_headers

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to match(/not authorized for notes/)
    end

    it "reads the travel calendar of an event in the series" do
      get "/api/v1/events/#{event.id}/travel", headers: series_headers

      expect(response).to have_http_status(:ok)
    end

    it "answers 403 rather than raising on an endpoint that needs a person" do
      get "/api/v1/events/#{event.id}/scan_contexts", headers: series_headers

      expect(response).to have_http_status(:forbidden)
    end
  end
end
