require "rails_helper"

RSpec.describe "Admin::Scans", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }
  let(:event) { create(:event, nfc_badges_enabled: false) }
  let(:participant_event) { create(:participant_event, event: event) }
  let(:scan_context) { event.scan_contexts.find_by!(checks_in: true) }

  before { sign_in admin }

  describe "POST /admin/events/:event_slug/scans" do
    {
      "a bare participant ID" => ->(pe) { pe.participant.id },
      "a bare participant event ID" => ->(pe) { pe.id },
      "an Apple Wallet participant deep link" => ->(pe) { "attend://checkin/#{pe.participant.id}" },
      "a participant event deep link" => ->(pe) { "attend://checkin/#{pe.id}" }
    }.each do |description, identifier|
      it "accepts #{description}" do
        expect {
          post admin_event_scans_path(event), params: {
            participant_id: identifier.call(participant_event),
            scan_context_id: scan_context.id
          }, as: :json
        }.to change { participant_event.scans.count }.by(1)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("participant", "participant_event_id")).to eq(participant_event.id)
      end
    end
  end

  it "shows NFC reading but hides writing when issuance is disabled" do
    get scanner_admin_event_scans_path(event)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("NFC Scanner")
    expect(response.body).not_to include('id="nfc-write-panel"', 'id="modal-write-nfc-btn"')
  end

  it "shows NFC writing when issuance is enabled" do
    event.update!(nfc_badges_enabled: true)

    get scanner_admin_event_scans_path(event)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("NFC Scanner", 'id="nfc-write-panel"', 'id="modal-write-nfc-btn"')
  end

  it "accepts an active personal token when event badge issuance is disabled" do
    owner = create(:user)
    participant = create(:participant, user: owner)
    participation = create(:participant_event, event: event, participant: participant)
    token = create(:nfc_token, :active, user: owner)

    post admin_event_scans_path(event), params: {
      badge_token: token.token,
      scan_context_id: scan_context.id
    }

    expect(response).to have_http_status(:ok)
    expect(participation.scans.last.source).to eq("nfc")
    expect(response.parsed_body.dig("participant", "participant_event_id")).to eq(participation.id)
  end

  it "confirms a pending user-owned token when issuance is enabled" do
    event.update!(nfc_badges_enabled: true)
    owner = create(:user)
    participation = create(:participant_event, event: event, participant: create(:participant, user: owner))
    token = create(:nfc_token, user: owner)

    post confirm_nfc_badge_admin_event_participant_event_path(event, participation),
      params: { badge_token: token.token }

    expect(response).to have_http_status(:ok)
    expect(token.reload).to be_active
    expect(token.paired_by).to eq(admin)
  end

  it "rejects confirmation when issuance is disabled" do
    owner = create(:user)
    participation = create(:participant_event, event: event, participant: create(:participant, user: owner))
    token = create(:nfc_token, user: owner)

    post confirm_nfc_badge_admin_event_participant_event_path(event, participation),
      params: { badge_token: token.token }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(token.reload).to be_pending
  end
end
