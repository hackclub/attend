require "rails_helper"

RSpec.describe "Api::V1::Scans", type: :request, fiat_registrations: true do
  include ActiveSupport::Testing::TimeHelpers

  let(:event) { create(:event, slug: "api-scans-#{SecureRandom.hex(8)}") }
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

    it "uses a bounded high-water timestamp so concurrent scans remain resumable" do
      cutoff = Time.zone.parse("2026-08-24 10:00:00")
      pe = create(:participant_event, event: event)
      context = event.scan_contexts.create!(name: "Check-in", checks_in: true)
      scan = pe.scans.create!(scan_context: context, user: admin, scanned_at: cutoff)
      scan.update_columns(created_at: cutoff + 1.second)

      travel_to(cutoff) do
        get "/api/v1/events/#{event.id}/scans",
          params: { since: (cutoff - 1.hour).iso8601(6) }, headers: auth_headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["scans"]).to be_empty
        expect(response.parsed_body["synced_at"]).to eq(cutoff.iso8601(6))
      end

      travel_to(cutoff + 2.seconds) do
        get "/api/v1/events/#{event.id}/scans",
          params: { since: cutoff.iso8601(6) }, headers: auth_headers

        expect(response.parsed_body["scans"].sole["id"]).to eq(scan.id)
      end
    end
  end

  describe "POST /api/v1/events/:event_id/scans" do
    let(:participant_event) { create(:participant_event, event: event) }
    let(:scan_context) { event.scan_contexts.find_by!(checks_in: true) }
    let(:client_scan_id) { SecureRandom.uuid }
    let(:scanned_at) { Time.zone.parse("2026-08-24 09:41:00") }

    def create_scan(participant_event:, scan_context:, client_scan_id:, scanned_at:)
      post "/api/v1/events/#{event.id}/scans",
        params: {
          participant_id: participant_event.id,
          scan_context_id: scan_context.id,
          client_scan_id: client_scan_id,
          scanned_at: scanned_at.iso8601
        },
        headers: auth_headers
    end

    it "returns the authoritative outcome, context, and participant snapshot" do
      participant_event.participant.headshot.attach(
        fixture_file_upload("headshot.png", "image/png")
      )
      create_scan(
        participant_event: participant_event,
        scan_context: scan_context,
        client_scan_id: client_scan_id,
        scanned_at: scanned_at
      )

      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json.slice("outcome", "first_scan_in_context")).to eq(
        "outcome" => "scanned",
        "first_scan_in_context" => true
      )
      expect(json["first_scanned_at"]).to eq(scanned_at.iso8601)
      expect(json["scan_context"]).to include(
        "id" => scan_context.id,
        "name" => scan_context.name,
        "checks_in" => true
      )
      expect(json["participant"]).to include(
        "participant_event_id" => participant_event.id,
        "checked_in_at" => scanned_at.iso8601
      )
      expect(json.dig("participant", "headshot_url")).to match(
        %r{\Ahttp://www\.example\.com/rails/active_storage/blobs/proxy/}
      )
      expect(json.dig("participant", "scans_by_context")).to contain_exactly(
        include(
          "scan_context_id" => scan_context.id,
          "scan_count" => 1,
          "first_scanned_at" => scanned_at.iso8601,
          "last_scanned_at" => scanned_at.iso8601
        )
      )
    end

    it "retains a repeat attempt and returns already scanned" do
      create_scan(
        participant_event: participant_event,
        scan_context: scan_context,
        client_scan_id: client_scan_id,
        scanned_at: scanned_at
      )
      create_scan(
        participant_event: participant_event,
        scan_context: scan_context,
        client_scan_id: SecureRandom.uuid,
        scanned_at: scanned_at + 1.minute
      )

      json = response.parsed_body
      expect(json.slice("outcome", "first_scan_in_context")).to eq(
        "outcome" => "already_scanned",
        "first_scan_in_context" => false
      )
      expect(json["first_scanned_at"]).to eq(scanned_at.iso8601)
      expect(json.dig("participant", "scans_by_context", 0, "scan_count")).to eq(2)
      expect(participant_event.scans.where(scan_context: scan_context).count).to eq(2)
    end

    it "deduplicates a transport retry without weakening the response contract" do
      create_scan(
        participant_event: participant_event,
        scan_context: scan_context,
        client_scan_id: client_scan_id,
        scanned_at: scanned_at
      )
      original_scan_id = response.parsed_body.dig("scan", "id")

      create_scan(
        participant_event: participant_event,
        scan_context: scan_context,
        client_scan_id: client_scan_id,
        scanned_at: scanned_at + 1.minute
      )

      json = response.parsed_body
      expect(json["outcome"]).to eq("scanned")
      expect(json["first_scan_in_context"]).to be(true)
      expect(json["deduplicated"]).to be(true)
      expect(json.dig("scan", "id")).to eq(original_scan_id)
      expect(json.dig("scan_context", "id")).to eq(scan_context.id)
      expect(participant_event.scans.count).to eq(1)
    end

    it "does not expose another event when a client id collides" do
      create_scan(
        participant_event: participant_event,
        scan_context: scan_context,
        client_scan_id: client_scan_id,
        scanned_at: scanned_at
      )
      other_event = create(:event, slug: "api-scans-other-#{SecureRandom.hex(8)}")
      other_participant_event = create(:participant_event, event: other_event)
      other_context = other_event.scan_contexts.find_by!(checks_in: true)

      post "/api/v1/events/#{other_event.id}/scans",
        params: {
          participant_id: other_participant_event.id,
          scan_context_id: other_context.id,
          client_scan_id: client_scan_id,
          scanned_at: (scanned_at + 1.minute).iso8601
        },
        headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).not_to have_key("participant")
      expect(other_participant_event.scans).to be_empty
    end
  end

  describe "DELETE /api/v1/events/:event_id/scans/:id" do
    it "advances the participant sync timestamp when scans are removed" do
      participant_event = create(:participant_event, event: event)
      scan_context = event.scan_contexts.find_by!(checks_in: true)
      participant_event.scans.create!(
        scan_context: scan_context,
        user: admin,
        scanned_at: Time.current
      )
      participant_event.update_column(:updated_at, 1.minute.ago)
      previous_updated_at = participant_event.reload.updated_at

      delete "/api/v1/events/#{event.id}/scans/#{participant_event.id}",
        params: { scan_context_id: scan_context.id },
        headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(participant_event.reload.updated_at).to be > previous_updated_at
      expect(participant_event.scans.where(scan_context: scan_context)).to be_empty
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

  describe "role gating" do
    let(:participant_event) { create(:participant_event, event: event) }
    let(:scan_context) { event.scan_contexts.find_by!(checks_in: true) }

    before do
      participant_event.participant.update!(phone: "+12025550143")
      Medical.create!(
        participant_event: participant_event,
        allergies: "Peanuts",
        medical_conditions: "Asthma",
        medications: "Inhaler",
        has_anaphylaxis_risk: true
      )
      Dietary.create!(participant_event: participant_event, diet_type: "vegetarian", life_threatening_allergies: "Peanuts")
      SafeguardingInfo.create!(participant_event: participant_event, freedom_waiver_granted: true, high_support_flag: true)
    end

    def scan_as(user)
      token = MobileToken.generate_for(user)
      post "/api/v1/events/#{event.id}/scans",
        params: { participant_id: participant_event.id, scan_context_id: scan_context.id },
        headers: { "Authorization" => "Bearer #{token.token}" },
        as: :json
      response.parsed_body["participant"]
    end

    def staff_with(role)
      create(:user).tap { |user| create(:event_role_assignment, user: user, event: event, role: role) }
    end

    it "gives a global admin everything" do
      participant = scan_as(admin)

      expect(participant).to include(
        "phone" => "+12025550143",
        "allergies" => "Peanuts",
        "medical_conditions" => "Asthma",
        "medications" => "Inhaler",
        "diet_type" => "vegetarian",
        "freedom_waiver_granted" => true
      )
    end

    it "keeps the phone number from limited staff, who still get full medical detail" do
      participant = scan_as(staff_with("limited"))

      expect(response).to have_http_status(:ok)
      expect(participant).not_to have_key("phone")
      expect(participant).not_to have_key("freedom_waiver_granted")
      expect(participant).to include(
        "allergies" => "Peanuts",
        "medical_conditions" => "Asthma",
        "medications" => "Inhaler"
      )
    end

    it "stops ops at allergies and dietary needs" do
      participant = scan_as(staff_with("ops"))

      expect(response).to have_http_status(:ok)
      expect(participant).to include(
        "phone" => "+12025550143",
        "allergies" => "Peanuts",
        "diet_type" => "vegetarian",
        "life_threatening_allergies" => "Peanuts",
        "has_anaphylaxis_risk" => true,
        "high_support_flag" => true
      )
      expect(participant.keys).not_to include("medical_conditions", "medications", "freedom_waiver_granted")
    end

    it "gives event admins full medical detail but not the safeguarding detail" do
      participant = scan_as(staff_with("event_admin"))

      expect(participant).to include("phone" => "+12025550143", "medical_conditions" => "Asthma", "medications" => "Inhaler")
      expect(participant).not_to have_key("freedom_waiver_granted")
    end

    it "gives safeguarding leads the safeguarding detail" do
      participant = scan_as(staff_with("safeguarding_lead"))

      expect(participant).to include("medical_conditions" => "Asthma", "freedom_waiver_granted" => true)
    end

    it "treats a series member as an event admin" do
      series = create(:event_series)
      event.update!(event_series: series)
      member = create(:user)
      SeriesRoleAssignment.create!(user: member, event_series: series, role: SeriesRoleAssignment.roles.keys.first)

      participant = scan_as(member)

      expect(response).to have_http_status(:ok)
      expect(participant).to include("phone" => "+12025550143", "medical_conditions" => "Asthma")
    end

    it "refuses a scan from read-only staff" do
      expect { scan_as(staff_with("read_only")) }.not_to change(Scan, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).not_to have_key("participant")
    end

    it "refuses an undo from read-only staff but still lets them list scans" do
      participant_event.scans.create!(scan_context: scan_context, user: admin, scanned_at: Time.current)
      token = MobileToken.generate_for(staff_with("read_only"))
      headers = { "Authorization" => "Bearer #{token.token}" }

      expect {
        delete "/api/v1/events/#{event.id}/scans/#{participant_event.id}", headers: headers
      }.not_to change(Scan, :count)
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/events/#{event.id}/scans", headers: headers
      expect(response).to have_http_status(:ok)
    end
  end
end
