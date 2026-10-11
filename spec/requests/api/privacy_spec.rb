require "rails_helper"

RSpec.describe "Privacy hub endpoints", type: :request do
  let(:past_event) { create(:event, starts_at: 3.weeks.ago, ends_at: 2.weeks.ago, registration_open_at: 2.months.ago, registration_close_at: 1.month.ago) }
  let!(:participant) { create(:participant, email: "attendee@example.com") }
  let!(:registration) { create(:participant_event, participant:, event: past_event) }

  before do
    reset_privacy_jwks_cache
    stub_privacy_jwks
  end

  def call_hub(path, claims)
    post path, headers: { "Authorization" => "Bearer #{privacy_token(claims)}", "Accept" => "application/json" }
  end

  it "answers a dry run with counts, echoing request_id and dry_run" do
    claims = privacy_claims(emails: [ "attendee@example.com" ])
    call_hub("/api/privacy/delete", claims)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("request_id" => claims[:request_id], "found" => true, "dry_run" => true, "retained" => [])
    expect(response.parsed_body["deleted"]).to include("participants" => 1, "participant_events" => 1)
    expect(Participant.exists?(participant.id)).to be(true)
  end

  it "erases on a real run, then answers found: false" do
    call_hub("/api/privacy/delete", privacy_claims(emails: [ "attendee@example.com" ], dry_run: false))

    expect(response).to have_http_status(:ok)
    expect(Participant.exists?(participant.id)).to be(false)

    call_hub("/api/privacy/delete", privacy_claims(emails: [ "attendee@example.com" ], dry_run: false))
    expect(response.parsed_body).to include("found" => false, "deleted" => {})
  end

  it "reports on export without changing anything" do
    call_hub("/api/privacy/export", privacy_claims(action: "export", emails: [ "attendee@example.com" ], dry_run: false))

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("found" => true, "dry_run" => false)
    expect(Participant.exists?(participant.id)).to be(true)
  end

  it "rejects a missing or bad token with 401" do
    post "/api/privacy/delete"
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "missing_token")

    call_hub("/api/privacy/delete", privacy_claims(aud: "flavortown"))
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects a token minted for the other endpoint" do
    call_hub("/api/privacy/export", privacy_claims(action: "delete", emails: [ "attendee@example.com" ], dry_run: false))

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "action_mismatch")
    expect(Participant.exists?(participant.id)).to be(true)
  end

  it "rejects a replayed token" do
    token = privacy_token(privacy_claims(emails: [ "attendee@example.com" ]))
    2.times { post "/api/privacy/delete", headers: { "Authorization" => "Bearer #{token}" } }

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "replayed")
  end

  it "answers 503 when the hub's keys are unreachable, so the hub retries" do
    stub_request(:get, Privacy::Token::JWKS_URL).to_timeout
    call_hub("/api/privacy/delete", privacy_claims(emails: [ "attendee@example.com" ]))

    expect(response).to have_http_status(:service_unavailable)
  end

  it "asks for manual review instead of erasing someone registered for an event still to come" do
    create(:participant_event, participant:, event: create(:event))
    call_hub("/api/privacy/delete", privacy_claims(emails: [ "attendee@example.com" ], dry_run: false))

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "manual_review_required", "reason" => "event_not_over")
    expect(Participant.exists?(participant.id)).to be(true)
  end
end
