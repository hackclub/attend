require "rails_helper"

RSpec.describe "Api::V1::NfcBadges", type: :request do
  let(:event) { create(:event, nfc_badges_enabled: true) }
  let(:admin) { create(:user, global_role: "global_admin") }
  let(:mobile_token) { MobileToken.generate_for(admin) }
  let(:participation) { create(:participant_event, event: event) }

  def headers
    { "Authorization" => "Bearer #{mobile_token.token}" }
  end

  def endpoint(action)
    "/api/v1/events/#{event.id}/participant_events/#{participation.id}/nfc_badge/#{action}"
  end

  it "rejects issuance when the event does not issue NFC badges" do
    event.update!(nfc_badges_enabled: false)

    post endpoint("ensure"), headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "ensures and confirms an event-scoped badge" do
    participation.update_columns(nfc_badge_token: nil)

    post endpoint("ensure"), headers: headers
    token = JSON.parse(response.body).fetch("badge_token")

    expect(response).to have_http_status(:ok)
    expect(participation.reload.nfc_badge_token).to eq(token)

    post endpoint("confirm"), params: { badge_token: token }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(participation.reload).to be_nfc_badge_assigned
    expect(participation.nfc_badge_assigned_by).to eq(admin)
    expect(AuditLog.last.record).to eq(participation)
  end

  it "rejects a mismatched badge token" do
    post endpoint("confirm"), params: { badge_token: SecureRandom.uuid }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(participation.reload).not_to be_nfc_badge_assigned
  end

  it "resets only this participation to a fresh badge token" do
    original = participation.nfc_badge_token
    participation.assign_nfc_badge!(user: admin)

    post endpoint("reset"), headers: headers

    expect(response).to have_http_status(:ok)
    expect(participation.reload.nfc_badge_token).not_to eq(original)
    expect(participation).not_to be_nfc_badge_assigned
    expect(JSON.parse(response.body).fetch("badge_token")).to eq(participation.nfc_badge_token)
  end
end
