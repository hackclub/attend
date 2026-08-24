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
end
