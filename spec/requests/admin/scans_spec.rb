require "rails_helper"

RSpec.describe "Admin::Scans", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveSupport::Testing::TimeHelpers

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

    # The scanner banner stays up after the scan, so it spells out the
    # resulting status, who scanned and when rather than a bare tick.
    it "returns the resulting status and when the scan was recorded" do
      freeze_time do
        post admin_event_scans_path(event), params: {
          participant_id: participant_event.id, scan_context_id: scan_context.id
        }, as: :json

        expect(response.parsed_body).to include(
          "scanned_by" => admin.display_name_or_fallback,
          "scanned_at" => Time.current.iso8601
        )
        expect(response.parsed_body.dig("participant", "display_status")).to eq(participant_event.display_status)
      end
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

    it "flags food allergies from both health records without sending their free text" do
      participant_event.create_medical!(allergies: "Penicillin", has_anaphylaxis_risk: true)
      participant_event.create_dietary!(diet_type: "vegan", life_threatening_allergies: "Peanuts", cross_contamination_risk: true)

      post admin_event_scans_path(event), params: {
        participant_id: participant_event.id, scan_context_id: scan_context.id
      }, as: :json

      expect(response.parsed_body["participant"]).to include(
        "has_anaphylaxis_risk" => true, "dietary" => "vegan", "has_allergies" => true,
        "has_life_threatening_food_allergies" => true, "cross_contamination_risk" => true
      )
      expect(response.body).not_to include("Peanuts", "Penicillin")
    end

    it "reads \"None\" in the allergy fields as no allergy" do
      participant_event.create_medical!(allergies: "None")
      participant_event.create_dietary!(life_threatening_allergies: "No known allergies")

      post admin_event_scans_path(event), params: {
        participant_id: participant_event.id, scan_context_id: scan_context.id
      }, as: :json

      expect(response.parsed_body["participant"]).to include(
        "has_allergies" => false, "has_life_threatening_food_allergies" => false
      )
    end

    it "leaves health-form allergies out for roles that can't see the medical summary" do
      # Read-only here, but staff elsewhere, so the admin area is open to them.
      read_only = create(:event_role_assignment, event: event, role: "read_only").user
      create(:event_role_assignment, user: read_only, event: create(:event), role: "ops")
      participant_event.create_medical!(allergies: "Penicillin")
      sign_in read_only

      post admin_event_scans_path(event), params: {
        participant_id: participant_event.id, scan_context_id: scan_context.id
      }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["participant"]).not_to have_key("has_allergies")
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

    expect(response.body).to include(%(<input type="hidden" id="scan-context" value="#{scan_context.id}"))
  end

  # Both admins carry their own copy of the scanner script, so pin each one
  # to the persistent banner and the queue for scans arriving mid-scan.
  { "the console" => true, "the old admin" => false }.each do |ui, console|
    it "keeps scan results up and queues scans made mid-scan in #{ui}" do
      admin.update!(admin_console_beta: console)

      get scanner_admin_event_scans_path(event)

      expect(response.body).to include('id="scan-queue-note"', "pendingScans.push", "data-scan-result-dismiss", "function submitScan")
      expect(response.body).not_to include("resultHideTimeout")
    end
  end

  it "renders the NFC write flag as false when NFC badges were never set up" do
    event.update!(nfc_badges_enabled: nil)

    get scanner_admin_event_scans_path(event)

    expect(response.body).to include("const nfcWriteOnCheckin = false;")
  end
end
