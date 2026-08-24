require "rails_helper"

RSpec.describe "Admin::TravelCalendar", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-travel-calendar@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event, timezone: "America/Los_Angeles") }

  before { sign_in admin }

  describe "GET /admin/events/:slug/travel" do
    it "renders the canonical travel calendar" do
      get "/admin/events/#{event.slug}/travel"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Travel Calendar")
      expect(response.body).to include(event.name)
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
