require "rails_helper"

RSpec.describe "Api::V1::Scans", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:event) { create(:event, slug: "api-scans-#{SecureRandom.hex(8)}") }
  let(:admin) { User.create!(email: "api-scans@example.com", name: "API Admin", global_role: "global_admin") }
  let(:mobile_token) { MobileToken.generate_for(admin) }

  def auth_headers
    { "Authorization" => "Bearer #{mobile_token.token}" }
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
end
