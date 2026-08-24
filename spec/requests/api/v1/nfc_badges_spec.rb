require "rails_helper"

RSpec.describe "Api::V1::NfcBadges", type: :request do
  let(:event) { create(:event, nfc_badges_enabled: true) }
  let(:admin) { create(:user, global_role: "global_admin") }
  let(:mobile_token) { MobileToken.generate_for(admin) }
  let(:owner) { create(:user) }
  let(:participant) { create(:participant, user: owner) }
  let(:participation) { create(:participant_event, event: event, participant: participant) }

  def headers
    { "Authorization" => "Bearer #{mobile_token.token}" }
  end

  def endpoint(action)
    "/api/v1/events/#{event.id}/participant_events/#{participation.id}/nfc_badge/#{action}"
  end

  it "rejects issuance when the event does not issue NFC hardware" do
    event.update!(nfc_badges_enabled: false)

    post endpoint("ensure"), headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(owner.nfc_tokens).to be_empty
  end

  it "rejects issuance for a participant without a user" do
    participation.update!(participant: create(:participant))

    post endpoint("ensure"), headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "ensures and confirms a user-owned token" do
    post endpoint("ensure"), headers: headers
    token_value = JSON.parse(response.body).fetch("badge_token")

    expect(response).to have_http_status(:ok)
    expect(owner.nfc_tokens.sole).to be_pending

    post endpoint("confirm"), params: { badge_token: token_value }, headers: headers

    expect(response).to have_http_status(:ok)
    token = owner.nfc_tokens.sole.reload
    expect(token).to be_active
    expect(token.paired_by).to eq(admin)
    expect(AuditLog.last.record).to eq(token)
    expect(AuditLog.last.metadata.to_json).not_to include(token_value)
  end

  it "rejects mismatches and confirmation without a pending token" do
    post endpoint("ensure"), headers: headers

    post endpoint("confirm"), params: { badge_token: SecureRandom.uuid }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)

    owner.nfc_tokens.pending.destroy_all
    post endpoint("confirm"), params: { badge_token: SecureRandom.uuid }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "resets to a fresh pending token without revoking active hardware" do
    active = create(:nfc_token, :active, user: owner)
    stale_pending = create(:nfc_token, user: owner)

    post endpoint("reset"), headers: headers

    expect(response).to have_http_status(:ok)
    replacement = owner.nfc_tokens.pending.sole
    expect(replacement).not_to eq(stale_pending)
    expect(stale_pending.reload.revoked_at).to be_present
    expect(active.reload).to be_active
    expect(JSON.parse(response.body).fetch("badge_token")).to eq(replacement.token)
    expect(AuditLog.last.metadata.to_json).not_to include(replacement.token)
  end
end
