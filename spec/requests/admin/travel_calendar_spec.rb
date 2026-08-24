require "rails_helper"

RSpec.describe "Admin::TravelCalendar", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-travel-calendar@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event, timezone: "America/Los_Angeles") }

  before { sign_in admin }

  describe "GET /admin/events/:slug/travel" do
    def create_journey(mode:, direction:, participant_event: nil, **attributes)
      participant_event ||= create(:participant_event, event: event, status: :complete)
      Travel.create!(participant_event: participant_event, mode: mode, direction: direction, **attributes)
    end

    it "renders every travel mode in one day-grouped agenda" do
      checked_in_registration = create(:participant_event, :checked_in, event: event, status: :complete)
      create_journey(mode: "train", direction: "inbound", participant_event: checked_in_registration, arrival_time: Time.utc(2026, 8, 24, 17), train_departure_station: "Oakland", train_arrival_station: "San Francisco", carrier: "Amtrak")
      plane = create_journey(mode: "plane", direction: "inbound")
      create(:travel_leg, travel: plane, departure_time: Time.utc(2026, 8, 24, 15), arrival_time: Time.utc(2026, 8, 24, 19), departure_airport: "JFK", arrival_airport: "SFO", flight_code: "UA123")
      create_journey(mode: "bus", direction: "outbound", departure_time: Time.utc(2026, 8, 25, 18), bus_departure_location: "Venue", bus_arrival_location: "SFO", carrier: "Event shuttle")
      create_journey(mode: "car", direction: "inbound", expected_arrival_time: Time.utc(2026, 8, 25, 20), origin_address: "Oakland")
      create_journey(mode: "other", direction: "outbound", other_details: "Collected by guardian")

      get "/admin/events/#{event.slug}/travel"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Travel Calendar")
      expect(response.body).to include(event.name)
      expect(response.body).to include("Monday 24 August")
      expect(response.body).to include("Tuesday 25 August")
      expect(response.body).to include("Unscheduled")
      expect(response.body).to include("Train", "Bus", "Car", "Flight", "Other")
      expect(response.body).to include("Awaiting pickup", "Checked in")
      expect(response.body).not_to include("Terminal", "Gate", "Refresh status")

      document = Nokogiri::HTML(response.body)
      expect(document.css("nav[aria-label='Travel filters']").size).to eq(1)
      expect(document.css("section[data-travel-calendar-filter-target~='day'] ol > li[data-travel-calendar-filter-target~='entry']").size).to eq(5)
      expect(document.css("li[data-travel-calendar-filter-target~='entry'] > details").size).to eq(5)
    end

    it "renders an empty-calendar explanation" do
      get "/admin/events/#{event.slug}/travel"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No travel has been scheduled yet.")
    end

    it "redirects to the event dashboard when travel is disabled" do
      event.update!(travel_enabled: false)

      get "/admin/events/#{event.slug}/travel"

      expect(response).to redirect_to(admin_event_dashboard_path(event.slug))
      follow_redirect!
      expect(response.body).to include("Travel is disabled for this event.")
    end

    it "redirects the legacy admin route and preserves filters" do
      get "/admin/events/#{event.slug}/airport_mode", params: { direction: "inbound" }

      expect(response).to redirect_to(admin_event_travel_path(event, direction: "inbound"))
    end
  end

  describe "POST /admin/events/:slug/travel/dismiss_pickup" do
    it "rejects dismissal for another event's travel" do
      other_event = create(:event)
      other_participant_event = create(:participant_event, event: other_event, status: :complete)
      other_event_travel = Travel.create!(
        participant_event: other_participant_event,
        direction: "inbound",
        mode: "bus"
      )

      post dismiss_pickup_admin_event_travel_path(event), params: { travel_id: other_event_travel.id }

      expect(response).to have_http_status(:not_found)
      expect(other_event_travel.reload).not_to be_pickup_dismissed
    end

    it "invalidates the cached pickup state after dismissal" do
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)
      participant_event = create(:participant_event, event: event, status: :complete)
      travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "bus")

      expect(TravelCalendar::JourneyCache.fetch(event).sole[:pickup_state]).to eq(:awaiting_pickup)

      post dismiss_pickup_admin_event_travel_path(event), params: { travel_id: travel.id }

      expect(response).to redirect_to(admin_event_travel_path(event))
      expect(TravelCalendar::JourneyCache.fetch(event).sole[:pickup_state]).to eq(:pickup_not_needed)
    end
  end

  describe "POST /admin/events/:slug/scans" do
    it "invalidates the cached pickup state after venue check-in" do
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)
      participant_event = create(:participant_event, event: event, status: :complete)
      travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "train")
      check_in = event.scan_contexts.find_by!(checks_in: true)

      expect(TravelCalendar::JourneyCache.fetch(event).sole[:pickup_state]).to eq(:awaiting_pickup)

      post admin_event_scans_path(event), params: {
        participant_id: participant_event.participant_id,
        scan_context_id: check_in.id
      }

      expect(response).to have_http_status(:ok)
      expect(TravelCalendar::JourneyCache.fetch(event).sole).to include(id: travel.id, pickup_state: :checked_in)
    end
  end
end
