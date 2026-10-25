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

    it "accepts an active passport when event badge issuance is disabled" do
      owner = create(:user)
      participant = create(:participant, user: owner)
      participation = create(:participant_event, event: event, participant: participant)
      passport = create(:passport, :active, user: owner)

      expect {
        post admin_event_scans_path(event), params: {
          badge_token: passport.token,
          scan_context_id: scan_context.id
        }, as: :json
      }.to change { participation.scans.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(participation.scans.last.source).to eq("nfc")
    end

    it "rejects a revoked passport" do
      owner = create(:user)
      participant = create(:participant, user: owner)
      participation = create(:participant_event, event: event, participant: participant)
      passport = create(:passport, :revoked, user: owner)

      post admin_event_scans_path(event), params: {
        badge_token: passport.token,
        scan_context_id: scan_context.id
      }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(participation.scans).to be_empty
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

  it "makes staff choose the scanner context when there are several, listed by start time" do
    tomorrow = event.scan_contexts.create!(name: "Tomorrow", starts_at: 1.day.from_now, ends_at: 1.day.from_now + 1.hour, position: 1)
    free_time = event.scan_contexts.create!(name: "Free time", starts_at: 1.hour.ago, ends_at: 1.hour.from_now, position: 2)

    get scanner_admin_event_scans_path(event)

    options = response.body[%r{<select id="scan-context".*?</select>}m].scan(/<option value="([^"]*)"( selected)?/)
    expect(options.select { |_, selected| selected }).to eq([ [ "", " selected" ] ])
    expect(options.map(&:first)).to eq([ "", free_time.id, tomorrow.id, scan_context.id ])
    expect(response.body).to include('id="scan-context-required"')
  end

  it "uses the only scan context without asking in the old admin" do
    admin.update!(admin_console_beta: false)

    get scanner_admin_event_scans_path(event)

    expect(response.body).to include(%(<input type="hidden" id="scan-context" value="#{scan_context.id}">))
  end
end
