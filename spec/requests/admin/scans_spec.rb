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

  # The scanner sends an id of its own with each scan and repeats it when it
  # retries after losing the connection.
  describe "retried scans" do
    let(:client_scan_id) { SecureRandom.uuid }

    def scan!(**params)
      post admin_event_scans_path(event), params: {
        participant_id: participant_event.id, scan_context_id: scan_context.id, **params
      }, as: :json
    end

    it "answers a retry with the scan already recorded" do
      scan!(client_scan_id: client_scan_id)
      first = response.parsed_body

      expect { scan!(client_scan_id: client_scan_id) }.not_to change(Scan, :count)

      expect(response).to have_http_status(:ok)
      expect(first).to include("deduplicated" => false, "first_scan_in_context" => true, "client_scan_id" => client_scan_id)
      expect(response.parsed_body).to include(
        "scan_id" => first["scan_id"],
        "scanned_at" => first["scanned_at"],
        "deduplicated" => true,
        "first_scan_in_context" => true
      )
    end

    it "keeps the first scanner's name on a retry sent by someone else" do
      scan!(client_scan_id: client_scan_id)
      other_admin = create(:user, global_role: "global_admin")
      sign_in other_admin

      scan!(client_scan_id: client_scan_id)

      expect(response.parsed_body["scanned_by"]).to eq(admin.display_name_or_fallback)
    end

    it "still records every scan sent without an id, or with ids of their own" do
      expect {
        scan!
        scan!
        scan!(client_scan_id: SecureRandom.uuid)
        scan!(client_scan_id: SecureRandom.uuid)
      }.to change { participant_event.scans.count }.by(4)

      expect(response.parsed_body).to include("deduplicated" => false, "first_scan_in_context" => false)
    end

    it "refuses an id already used for a different person" do
      other = create(:participant_event, event: event)
      scan!(client_scan_id: client_scan_id)

      expect {
        scan!(client_scan_id: client_scan_id, participant_id: other.id)
      }.not_to change(Scan, :count)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).not_to have_key("participant")
    end

    it "refuses an id already used at a different scan point" do
      elsewhere = event.scan_contexts.create!(name: "Side door", starts_at: 1.hour.ago, ends_at: 1.hour.from_now, position: 9)
      scan!(client_scan_id: client_scan_id)

      expect {
        scan!(client_scan_id: client_scan_id, scan_context_id: elsewhere.id)
      }.not_to change(Scan, :count)

      expect(response).to have_http_status(:conflict)
    end

    it "rejects an id that isn't shaped like one" do
      expect { scan!(client_scan_id: "x" * 200) }.not_to change(Scan, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "audits the scan once, not each retry" do
      # The first POST after sign-in audits the user Devise just tracked.
      get scanner_admin_event_scans_path(event)

      expect { scan!(client_scan_id: client_scan_id) }.to change { AuditLog.where(record_type: "Scan").count }.by(1)

      log = AuditLog.where(record_type: "Scan").order(:created_at).last
      expect(log).to have_attributes(action: "record_create", actor: admin, event: event, record_id: response.parsed_body["scan_id"])
      expect(log.changed_fields).to include("client_scan_id", "scanned_at", "participant_event_id")

      expect { scan!(client_scan_id: client_scan_id) }.not_to change(AuditLog, :count)
    end

    it "doesn't repeat the first scan's side effects on a retry" do
      event.update!(nfc_badges_enabled: true)
      scan!(client_scan_id: client_scan_id)
      token = participant_event.reload.nfc_badge_token
      participant_event.update_columns(nfc_badge_token: nil)

      scan!(client_scan_id: client_scan_id)

      expect(token).to be_present
      expect(participant_event.reload.nfc_badge_token).to be_nil
    end
  end

  # A scan held on a device is sent late, so the device says when it scanned
  # and when it sent; see ScanTimestamp for how far that is believed.
  describe "device scan times" do
    def scan!(**params)
      post admin_event_scans_path(event), params: {
        participant_id: participant_event.id, scan_context_id: scan_context.id, **params
      }, as: :json
    end

    it "backdates a scan by how long the device held it, and keeps the device's own time" do
      freeze_time do
        scan!(client_scanned_at: 10.minutes.ago.iso8601(3), client_sent_at: Time.current.iso8601(3))

        scan = participant_event.scans.last
        expect(scan.scanned_at).to be_within(1.second).of(10.minutes.ago)
        expect(scan.client_scanned_at).to be_within(1.second).of(10.minutes.ago)
        expect(scan.created_at).to be_within(1.second).of(Time.current)
        expect(response.parsed_body).to include("scanned_at" => 10.minutes.ago.iso8601, "time_adjusted" => false)
      end
    end

    it "is not thrown by a device whose clock is wrong" do
      freeze_time do
        device_now = 3.days.from_now
        scan!(client_scanned_at: (device_now - 10.minutes).iso8601(3), client_sent_at: device_now.iso8601(3))

        scan = participant_event.scans.last
        expect(scan.scanned_at).to be_within(1.second).of(10.minutes.ago)
        expect(scan.client_scanned_at).to be_within(1.second).of(device_now - 10.minutes)
      end
    end

    it "records the server's time when the device held the scan too long" do
      freeze_time do
        claimed = Time.current - ScanTimestamp::MAX_AGE - 1.minute
        scan!(client_scanned_at: claimed.iso8601(3), client_sent_at: Time.current.iso8601(3))

        scan = participant_event.scans.last
        expect(scan.scanned_at).to be_within(1.second).of(Time.current)
        expect(scan.client_scanned_at).to be_within(1.second).of(claimed)
        expect(response.parsed_body["time_adjusted"]).to be(true)
      end
    end

    it "records the server's time for a scan dated after it was sent" do
      freeze_time do
        scan!(client_scanned_at: 1.hour.from_now.iso8601(3), client_sent_at: Time.current.iso8601(3))

        expect(participant_event.scans.last.scanned_at).to be_within(1.second).of(Time.current)
        expect(response.parsed_body["time_adjusted"]).to be(true)
      end
    end

    it "never records a scan in the future" do
      freeze_time do
        scan!(client_scanned_at: 1.minute.from_now.iso8601(3))

        expect(participant_event.scans.last.scanned_at).to be_within(1.second).of(Time.current)
      end
    end

    it "falls back to the server's time for a time it can't read" do
      freeze_time do
        scan!(client_scanned_at: "yesterday-ish")

        scan = participant_event.scans.last
        expect(response).to have_http_status(:ok)
        expect(scan.scanned_at).to be_within(1.second).of(Time.current)
        expect(scan.client_scanned_at).to be_nil
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

  # Both admins share one scanner (app/javascript/scanner); each view is
  # markup, the elements the scanner paints into, and the mount point.
  { "the console" => [ true, "console" ], "the old admin" => [ false, "classic" ] }.each do |ui, (console, skin)|
    it "mounts the shared scanner with no inline script in #{ui}" do
      admin.update!(admin_console_beta: console)

      get scanner_admin_event_scans_path(event)

      page = Nokogiri::HTML(response.body)
      mount = page.at_css('[data-controller="scanner"]')
      config = JSON.parse(mount["data-scanner-config-value"])
      expect(config).to include(
        "skin" => skin,
        "eventId" => event.id,
        "userId" => admin.id,
        "scanUrl" => admin_event_scans_path(event),
        "searchUrl" => search_admin_event_scans_path(event),
        "contexts" => { scan_context.id => scan_context.name }
      )
      expect(page.css("#scan-result, #scan-queue-note, #scan-sync, #participant-modal").size).to eq(4)
      expect(mount.css("template[data-scanner-icon]").size).to eq(console ? 4 : 0)
      expect(response.body).not_to include("function submitScan", "pendingScans")
    end
  end

  # The service worker keeps this copy on the device for reloading offline,
  # so it must not carry anyone's name.
  it "renders the offline shell without the day's scans" do
    participant_event.scans.create!(scan_context: scan_context, user: admin, scanned_at: Time.current)

    get scanner_admin_event_scans_path(event)
    expect(response.body).to include(participant_event.participant.display_name)

    get scanner_admin_event_scans_path(event, shell: 1)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(participant_event.participant.display_name)
    expect(response.body).to include("Scans from today are not shown without a connection.", 'data-controller="scanner"')
    expect(response.body).not_to include('id="scan-count"')
  end

  # Scan times are instants; "today" and the history's date filter are days
  # on the event's clock, not UTC days.
  describe "event-local days" do
    # Los Angeles: UTC-7 in July.
    let(:event) { create(:event, nfc_badges_enabled: false, timezone: "Pacific Time (US & Canada)") }

    def scan_at(time)
      participant_event.scans.create!(scan_context: scan_context, user: admin, scanned_at: time)
    end

    it "filters the history to the chosen day on the event's clock" do
      evening_before = scan_at(Time.utc(2030, 7, 12, 3, 0)) # July 11, 20:00 in Los Angeles
      morning = scan_at(Time.utc(2030, 7, 12, 16, 0))       # July 12, 09:00
      late_evening = scan_at(Time.utc(2030, 7, 13, 5, 0))   # July 12, 22:00

      [ true, false ].each do |console|
        admin.update!(admin_console_beta: console)

        get history_admin_event_scans_path(event, date: "2030-07-12")

        expect(response.body).to include("scan-row-#{morning.id}", "scan-row-#{late_evening.id}")
        expect(response.body).not_to include("scan-row-#{evening_before.id}")
        expect(response.body).to include("In the event&#39;s time zone: Pacific Time (US &amp; Canada).")
      end
    end

    it "counts today's scans by the event's day" do
      travel_to Time.utc(2030, 7, 12, 5, 0) do # July 11, 22:00 in Los Angeles
        scan_at(Time.utc(2030, 7, 11, 16, 0)) # July 11, 09:00: today at the event, yesterday in UTC
        scan_at(Time.utc(2030, 7, 12, 4, 0))  # July 11, 21:00
        scan_at(Time.utc(2030, 7, 11, 6, 0))  # July 10, 23:00: yesterday at the event

        get admin_event_scans_path(event)
        expect(response.body).to match(%r{Scans today</dt><dd[^>]*>2</dd>})

        get scanner_admin_event_scans_path(event)
        expect(response.body).to match(%r{data-event-scans-target="count">2</span> scans today})
      end
    end
  end

  it "renders the NFC write flag as false when NFC badges were never set up" do
    event.update!(nfc_badges_enabled: nil)

    get scanner_admin_event_scans_path(event)

    mount = Nokogiri::HTML(response.body).at_css('[data-controller="scanner"]')
    expect(JSON.parse(mount["data-scanner-config-value"])).to include("nfcWriteOnCheckin" => false)
  end
end
