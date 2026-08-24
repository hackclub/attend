require "rails_helper"

RSpec.describe "Api::V1::Scans", type: :request do
  let(:event) { create(:event) }
  let(:admin) { User.create!(email: "api-scans@example.com", name: "API Admin", global_role: "global_admin") }
  let(:mobile_token) { MobileToken.generate_for(admin) }

  def auth_headers
    { "Authorization" => "Bearer #{mobile_token.token}" }
  end

  describe "POST /api/v1/events/:event_id/scans" do
    let(:participant_event) { create(:participant_event, event: event) }
    let(:scan_context) { event.scan_contexts.find_by!(checks_in: true) }

    {
      "a bare participant ID" => ->(pe) { pe.participant.id },
      "a bare participant event ID" => ->(pe) { pe.id },
      "an Apple Wallet participant deep link" => ->(pe) { "attend://checkin/#{pe.participant.id}" },
      "a participant event deep link" => ->(pe) { "attend://checkin/#{pe.id}" }
    }.each do |description, identifier|
      it "accepts #{description}" do
        expect {
          post "/api/v1/events/#{event.id}/scans", params: {
            participant_id: identifier.call(participant_event),
            scan_context_id: scan_context.id
          }, headers: auth_headers, as: :json
        }.to change { participant_event.scans.count }.by(1)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("participant", "participant_event_id")).to eq(participant_event.id)
      end
    end

    it "accepts an active passport when event badge issuance is disabled" do
      event.update!(nfc_badges_enabled: false)
      owner = create(:user)
      participant = create(:participant, user: owner)
      participation = create(:participant_event, event: event, participant: participant)
      passport = create(:passport, :active, user: owner)

      expect {
        post "/api/v1/events/#{event.id}/scans",
          params: { badge_token: passport.token, scan_context_id: scan_context.id },
          headers: auth_headers,
          as: :json
      }.to change { participation.scans.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(participation.scans.last.source).to eq("nfc")
    end

    it "rejects a passport whose owner is not participating in the selected event" do
      owner = create(:user)
      participant = create(:participant, user: owner)
      other_participation = create(:participant_event, participant: participant)
      passport = create(:passport, :active, user: owner)

      post "/api/v1/events/#{event.id}/scans",
        params: { badge_token: passport.token, scan_context_id: scan_context.id },
        headers: auth_headers,
        as: :json

      expect(response).to have_http_status(:not_found)
      expect(other_participation.scans).to be_empty
    end
  end

  describe "GET /api/v1/events/:event_id/scans with since" do
    it "caps the response and marks it resumable" do
      stub_const("Api::V1::ScansController::SINCE_SYNC_LIMIT", 3)

      pe = create(:participant_event, event: event)
      context = event.scan_contexts.create!(name: "Check-in", checks_in: true)
      5.times { |i| pe.scans.create!(scan_context: context, user: admin, scanned_at: (10 - i).minutes.ago) }

      get "/api/v1/events/#{event.id}/scans",
        params: { since: 1.day.ago.iso8601 }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["scans"].size).to eq(3)
      expect(json["has_more"]).to be(true)

      # synced_at resumes after the last delivered scan: a follow-up poll
      # returns the remaining scans instead of losing them.
      get "/api/v1/events/#{event.id}/scans",
        params: { since: json["synced_at"] }, headers: auth_headers

      followup = JSON.parse(response.body)
      expect(followup["scans"].size).to eq(2)
      expect(followup["has_more"]).to be(false)
    end

    it "returns everything with has_more false when under the cap" do
      pe = create(:participant_event, event: event)
      context = event.scan_contexts.create!(name: "Check-in", checks_in: true)
      2.times { pe.scans.create!(scan_context: context, user: admin, scanned_at: 5.minutes.ago) }

      get "/api/v1/events/#{event.id}/scans",
        params: { since: 1.day.ago.iso8601 }, headers: auth_headers

      json = JSON.parse(response.body)
      expect(json["scans"].size).to eq(2)
      expect(json["has_more"]).to be(false)
    end
  end

  describe "POST /api/v1/events/:event_id/scans" do
    it "invalidates the journey cache after an explicit travel pickup scan" do
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)
      participant_event = create(:participant_event, event: event, status: :complete)
      pickup = event.scan_contexts.create!(name: "Station pickup", checks_in: false, is_travel_pickup: true)
      travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "train")

      expect(TravelCalendar::JourneyCache.fetch(event).sole[:pickup_state]).to eq(:awaiting_pickup)

      post "/api/v1/events/#{event.id}/scans",
        params: { participant_id: participant_event.id, scan_context_id: pickup.id }.to_json,
        headers: auth_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(TravelCalendar::JourneyCache.fetch(event).sole).to include(id: travel.id, pickup_state: :collected)
    end

    it "invalidates the journey cache after venue check-in" do
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)
      participant_event = create(:participant_event, event: event, status: :complete)
      check_in = event.scan_contexts.find_by!(checks_in: true)
      travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "bus")

      expect(TravelCalendar::JourneyCache.fetch(event).sole[:pickup_state]).to eq(:awaiting_pickup)

      post "/api/v1/events/#{event.id}/scans",
        params: { participant_id: participant_event.id, scan_context_id: check_in.id }.to_json,
        headers: auth_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(TravelCalendar::JourneyCache.fetch(event).sole).to include(id: travel.id, pickup_state: :checked_in)
    end

    it "marks the final inbound flight leg for an explicit travel pickup scan" do
      participant_event = create(:participant_event, event: event)
      pickup = event.scan_contexts.create!(name: "Station pickup", checks_in: false, is_travel_pickup: true)
      travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "plane")
      leg = create(:travel_leg, travel: travel, departure_airport: "SFO", arrival_airport: "BOS")

      post "/api/v1/events/#{event.id}/scans",
        params: { participant_id: participant_event.id, scan_context_id: pickup.id }.to_json,
        headers: auth_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("scan", "scan_context")).to include(
        "is_travel_pickup" => true,
        "is_airport" => true
      )
      expect(leg.reload).to be_travel_picked_up
    end

    it "preserves the original pickup timestamp on a duplicate explicit pickup scan" do
      participant_event = create(:participant_event, event: event)
      pickup = event.scan_contexts.create!(name: "Station pickup", checks_in: false, is_travel_pickup: true)
      travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "plane")
      leg = create(:travel_leg, travel: travel, departure_airport: "SFO", arrival_airport: "BOS")

      post "/api/v1/events/#{event.id}/scans",
        params: { participant_id: participant_event.id, scan_context_id: pickup.id }.to_json,
        headers: auth_headers.merge("Content-Type" => "application/json")

      original_pickup_time = leg.reload.travel_picked_up_at

      post "/api/v1/events/#{event.id}/scans",
        params: { participant_id: participant_event.id, scan_context_id: pickup.id }.to_json,
        headers: auth_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(leg.reload.travel_picked_up_at).to eq(original_pickup_time)
    end

    it "records a non-plane pickup scan without marking a legacy travel leg" do
      participant_event = create(:participant_event, event: event)
      pickup = event.scan_contexts.create!(name: "Station pickup", checks_in: false, is_travel_pickup: true)
      travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "train")
      legacy_leg = create(:travel_leg, travel: travel, departure_airport: "SFO", arrival_airport: "BOS")

      post "/api/v1/events/#{event.id}/scans",
        params: { participant_id: participant_event.id, scan_context_id: pickup.id }.to_json,
        headers: auth_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(legacy_leg.reload).not_to be_travel_picked_up
    end
  end

  describe "DELETE /api/v1/events/:event_id/scans/:id" do
    it "invalidates the journey cache when undoing a pickup scan" do
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)
      participant_event = create(:participant_event, event: event, status: :complete)
      pickup = event.scan_contexts.create!(name: "Station pickup", checks_in: false, is_travel_pickup: true)
      travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "train")
      participant_event.scans.create!(scan_context: pickup, user: admin, scanned_at: Time.current)

      expect(TravelCalendar::JourneyCache.fetch(event).sole).to include(id: travel.id, pickup_state: :collected)

      delete "/api/v1/events/#{event.id}/scans/#{participant_event.id}",
        params: { scan_context_id: pickup.id }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include("deleted_scans" => 1)
      expect(TravelCalendar::JourneyCache.fetch(event).sole).to include(id: travel.id, pickup_state: :awaiting_pickup)
    end
  end
end
