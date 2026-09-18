require "rails_helper"

RSpec.describe "Api::V1::Participants", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:event) { create(:event, nfc_badges_enabled: true) }
  let(:admin) { User.create!(email: "api-admin@example.com", name: "API Admin", global_role: "global_admin") }
  let(:mobile_token) { MobileToken.generate_for(admin) }

  def auth_headers
    { "Authorization" => "Bearer #{mobile_token.token}" }
  end

  describe "GET /api/v1/events/:event_id/participants" do
    it "returns the sync payload with checked-in time from the earliest check-in scan" do
      pe = create(:participant_event, event: event)
      context = event.scan_contexts.create!(name: "Check-in", checks_in: true)
      later = pe.scans.create!(scan_context: context, user: admin, scanned_at: 1.hour.ago)
      earliest = pe.scans.create!(scan_context: context, user: admin, scanned_at: 2.hours.ago)

      get "/api/v1/events/#{event.id}/participants", headers: auth_headers

      expect(response).to have_http_status(:ok)
      participant = JSON.parse(response.body)["participants"].sole
      expect(participant["participant_event_id"]).to eq(pe.id)
      expect(participant["checked_in_at"]).to eq(earliest.scanned_at.iso8601)
      expect(participant["scans_by_context"].sole["scan_count"]).to eq(2)
    end

    it "returns canonical and deprecated travel pickup fields" do
      pe = create(:participant_event, event: event)
      context = event.scan_contexts.create!(name: "Station pickup", is_travel_pickup: true)
      pe.scans.create!(scan_context: context, user: admin, scanned_at: 1.hour.ago)
      travel = Travel.create!(participant_event: pe, direction: "inbound", mode: "plane")
      leg = create(
        :travel_leg,
        travel: travel,
        departure_airport: "LHR",
        arrival_airport: "JFK",
        travel_picked_up_at: Time.utc(2026, 8, 24, 12, 0)
      )

      get "/api/v1/events/#{event.id}/participants", headers: auth_headers

      expect(response).to have_http_status(:ok)
      participant = JSON.parse(response.body)["participants"].sole
      expect(participant["scans_by_context"].sole).to include(
        "is_travel_pickup" => true,
        "is_airport" => true
      )
      expect(participant["travel_inbound"]["legs"].sole).to include(
        "travel_picked_up_at" => leg.travel_picked_up_at.iso8601,
        "airport_picked_up_at" => leg.travel_picked_up_at.iso8601
      )
    end

    it "exposes the NFC badge token without writing or enqueuing wallet-pass jobs" do
      pe = create(:participant_event, event: event)
      expect(pe.nfc_badge_token).to be_present # DB default backfills new rows

      updates = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql].to_s
        updates << sql if sql.start_with?("UPDATE", "INSERT")
      end

      expect {
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          get "/api/v1/events/#{event.id}/participants", headers: auth_headers
        end
      }.not_to have_enqueued_job(WalletPassUpdateJob)

      expect(response).to have_http_status(:ok)
      participant = JSON.parse(response.body)["participants"].sole
      expect(participant["nfc_badge_token"]).to eq(pe.reload.nfc_badge_token)
      expect(updates.grep(/participant_events/)).to be_empty
    end

    it "uses a bounded high-water timestamp so concurrent updates remain resumable" do
      cutoff = Time.zone.parse("2026-08-24 10:00:00")
      pe = create(:participant_event, event: event)
      pe.update_columns(updated_at: cutoff + 1.second)

      travel_to(cutoff) do
        get "/api/v1/events/#{event.id}/participants", headers: auth_headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["participants"]).to be_empty
        expect(response.parsed_body["synced_at"]).to eq(cutoff.iso8601(6))
      end

      travel_to(cutoff + 2.seconds) do
        get "/api/v1/events/#{event.id}/participants",
          params: { updated_since: cutoff.iso8601(6) }, headers: auth_headers

        expect(response.parsed_body["participants"].sole["participant_event_id"]).to eq(pe.id)
      end
    end
  end

  describe "GET /api/v1/events/:event_id/participants/lookup" do
    let(:api_key) do
      event.generate_api_key!
      event.api_key
    end

    def api_key_headers
      { "Authorization" => "Bearer #{api_key}" }
    end

    it "reports a registered participant, case-insensitively, without side effects" do
      participant = create(:participant, email: "voter@example.com")
      create(:participant_event, participant: participant, event: event)

      expect {
        get "/api/v1/events/#{event.id}/participants/lookup",
          params: { email: "VOTER@example.com" }, headers: api_key_headers
      }.to not_change(Participant, :count).and not_change(event.invitations, :count)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["registered"]).to be(true)
      expect(body["participant_id"]).to eq(participant.id)
    end

    it "reports a non-participant as not registered" do
      get "/api/v1/events/#{event.id}/participants/lookup",
        params: { email: "stranger@example.com" }, headers: api_key_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["registered"]).to be(false)
      expect(body["participant_id"]).to be_nil
    end

    it "requires an email" do
      get "/api/v1/events/#{event.id}/participants/lookup", headers: api_key_headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "still forbids an event API key from reading the full roster" do
      get "/api/v1/events/#{event.id}/participants", headers: api_key_headers

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/events/:event_id/participants/roster" do
    let(:api_key) do
      event.generate_api_key!
      event.api_key
    end

    def api_key_headers
      { "Authorization" => "Bearer #{api_key}" }
    end

    it "returns email, name, Slack ID, and status only — nothing else" do
      participant = create(:participant, email: "roster@example.com")
      pe = create(:participant_event, participant: participant, event: event)

      get "/api/v1/events/#{event.id}/participants/roster", headers: api_key_headers

      expect(response).to have_http_status(:ok)
      entry = JSON.parse(response.body)["participants"].sole
      expect(entry).to eq(
        "email" => "roster@example.com",
        "first_name" => participant.legal_first_name,
        "last_name" => participant.legal_last_name,
        "slack_user_id" => participant.slack_user_id,
        "status" => pe.status
      )
    end

    it "prefers the preferred name over the legal first name" do
      participant = create(:participant, preferred_name: "Ro")
      create(:participant_event, participant: participant, event: event)

      get "/api/v1/events/#{event.id}/participants/roster", headers: api_key_headers

      entry = JSON.parse(response.body)["participants"].sole
      expect(entry["first_name"]).to eq("Ro")
      expect(entry["last_name"]).to eq(participant.legal_last_name)
    end

    it "excludes withdrawn and rejected registrations" do
      active = create(:participant_event, event: event)
      create(:participant_event, event: event, status: :withdrawn)
      create(:participant_event, event: event, status: :rejected)

      get "/api/v1/events/#{event.id}/participants/roster", headers: api_key_headers

      expect(response).to have_http_status(:ok)
      emails = JSON.parse(response.body)["participants"].map { |p| p["email"] }
      expect(emails).to eq([ active.participant.email ])
    end

    it "rejects an API key belonging to a different event" do
      other_event = create(:event)
      other_event.generate_api_key!

      get "/api/v1/events/#{event.id}/participants/roster",
        headers: { "Authorization" => "Bearer #{other_event.api_key}" }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "authenticating with an EventApiToken" do
    let(:token_owner) { create(:user) }
    let(:event_token) do
      EventApiToken.generate_for(event, user: token_owner, name: "integration-test")
    end

    def event_token_headers
      { "Authorization" => "Bearer #{event_token.token}" }
    end

    it "allows lookup for the token's own event and touches last_used_at" do
      participant = create(:participant, email: "voter@example.com")
      create(:participant_event, participant: participant, event: event)
      expect(event_token.last_used_at).to be_nil

      get "/api/v1/events/#{event.id}/participants/lookup",
        params: { email: "voter@example.com" }, headers: event_token_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["registered"]).to be(true)
      expect(event_token.reload.last_used_at).to be_present
    end

    it "allows roster for the token's own event" do
      participant = create(:participant, email: "roster@example.com")
      pe = create(:participant_event, participant: participant, event: event)

      get "/api/v1/events/#{event.id}/participants/roster", headers: event_token_headers

      expect(response).to have_http_status(:ok)
      entry = JSON.parse(response.body)["participants"].sole
      expect(entry["email"]).to eq("roster@example.com")
      expect(entry["status"]).to eq(pe.status)
    end

    it "rejects a token belonging to a different event" do
      other_event = create(:event)

      get "/api/v1/events/#{other_event.id}/participants/roster", headers: event_token_headers

      expect(response).to have_http_status(:forbidden)
    end

    it "still forbids an event token from reading the full roster" do
      get "/api/v1/events/#{event.id}/participants", headers: event_token_headers

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects a revoked token" do
      event_token.revoke!

      get "/api/v1/events/#{event.id}/participants/roster", headers: event_token_headers

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/events/:event_id/participants" do
    def sign_in_headers_for(role)
      user = User.create!(email: "#{role}-api-invite@example.com", name: role.titleize)
      EventRoleAssignment.create!(user: user, event: event, role: role)
      { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" }
    end

    it "lets an event admin invite" do
      expect {
        post "/api/v1/events/#{event.id}/participants",
          params: { email: "invitee@example.com" }, headers: sign_in_headers_for("event_admin")
      }.to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(response).to have_http_status(:created)
    end

    it "lets an event API key invite" do
      event_token = EventApiToken.generate_for(event, user: create(:user), name: "integration")

      expect {
        post "/api/v1/events/#{event.id}/participants",
          params: { email: "keyed@example.com" },
          headers: { "Authorization" => "Bearer #{event_token.token}" }
      }.to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(response).to have_http_status(:created)
    end

    %w[limited ops safeguarding_lead].each do |role|
      it "forbids #{role}, who can read the roster but not add to it" do
        headers = sign_in_headers_for(role)

        get "/api/v1/events/#{event.id}/participants", headers: headers
        expect(response).to have_http_status(:ok)

        expect {
          post "/api/v1/events/#{event.id}/participants",
            params: { email: "sneaky@example.com" }, headers: headers
        }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "PATCH /api/v1/events/:event_id/participants/:id" do
    let(:participant) { create(:participant, legal_first_name: "Robin", preferred_name: nil, phone: "+12025550100") }
    let!(:participant_event) { create(:participant_event, participant: participant, event: event) }

    let(:api_key) do
      event.generate_api_key!
      event.api_key
    end

    def api_key_headers
      { "Authorization" => "Bearer #{api_key}" }
    end

    it "updates only the fields it was sent" do
      patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
        params: { participant: { preferred_name: "Rob" } }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["participant"]["display_name"]).to eq("Rob")
      participant.reload
      expect(participant.preferred_name).to eq("Rob")
      expect(participant.legal_first_name).to eq("Robin")
      expect(participant.phone).to eq("+12025550100")
    end

    it "withdraws and reinstates a registration, auditing each as the web does" do
      patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
        params: { status: "withdrawn" }, headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(participant_event.reload.status).to eq("withdrawn")
      expect(AuditLog.where(action: "withdraw", event: event)).to exist

      patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
        params: { status: "in_progress" }, headers: auth_headers
      expect(participant_event.reload.status).to eq("in_progress")
      expect(AuditLog.where(action: "unwithdraw", event: event)).to exist
    end

    it "rejects a status that isn't one of the registration states" do
      patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
        params: { status: "vibing" }, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("in_progress")
      expect(participant_event.reload.status).to eq("in_progress")
    end

    it "rejects an empty request rather than reporting a no-op as success" do
      patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}", headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "surfaces model validation failures without writing anything" do
      patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
        params: { participant: { phone: "12345", preferred_name: "Rob" } }, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/phone/i)
      participant.reload
      expect(participant.preferred_name).to be_nil
      expect(participant.phone).to eq("+12025550100")
    end

    it "lets an API key write a phone number it is not allowed to read back" do
      patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
        params: { participant: { phone: "+12025550199" } }, headers: api_key_headers

      expect(response).to have_http_status(:ok)
      expect(participant.reload.phone).to eq("+12025550199")
      body = JSON.parse(response.body)["participant"]
      expect(body).not_to have_key("phone")
      expect(body["email"]).to eq(participant.email)
      log = AuditLog.find_by(action: "update", event: event)
      expect(log.metadata["source"]).to eq("event_api")
    end

    it "refuses an API key issued for another event" do
      other_event = create(:event)
      other_pe = create(:participant_event, event: other_event)

      patch "/api/v1/events/#{other_event.id}/participants/#{other_pe.id}",
        params: { participant: { preferred_name: "Nope" } }, headers: api_key_headers

      expect(response).to have_http_status(:forbidden)
      expect(other_pe.participant.reload.preferred_name).to be_nil
    end

    it "refuses a staff role that cannot edit participants" do
      read_only = create(:event_role_assignment, event: event, role: "read_only").user

      patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
        params: { participant: { preferred_name: "Rob" } },
        headers: { "Authorization" => "Bearer #{MobileToken.generate_for(read_only).token}" }

      expect(response).to have_http_status(:forbidden)
      expect(participant.reload.preferred_name).to be_nil
    end

    it "404s for a participant_event on another event" do
      elsewhere = create(:participant_event)

      patch "/api/v1/events/#{event.id}/participants/#{elsewhere.id}",
        params: { participant: { preferred_name: "Rob" } }, headers: auth_headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/events/:event_id/participants/:id" do
    let!(:participant_event) { create(:participant_event, event: event) }

    it "removes the registration but keeps the person and their other events" do
      other_event = create(:event)
      elsewhere = create(:participant_event, participant: participant_event.participant, event: other_event)

      delete "/api/v1/events/#{event.id}/participants/#{participant_event.id}", headers: auth_headers

      expect(response).to have_http_status(:no_content)
      expect(ParticipantEvent.exists?(participant_event.id)).to be(false)
      expect(ParticipantEvent.exists?(elsewhere.id)).to be(true)
      expect(Participant.exists?(participant_event.participant_id)).to be(true)
      expect(AuditLog.where(action: "destroy", event: event)).to exist
    end

    it "refuses a role that isn't an event admin" do
      ops = create(:event_role_assignment, event: event, role: "ops").user

      delete "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
        headers: { "Authorization" => "Bearer #{MobileToken.generate_for(ops).token}" }

      expect(response).to have_http_status(:forbidden)
      expect(ParticipantEvent.exists?(participant_event.id)).to be(true)
    end

    it "lets an event API key remove a registration on its own event only" do
      event.generate_api_key!
      headers = { "Authorization" => "Bearer #{event.api_key}" }
      other_event = create(:event)
      elsewhere = create(:participant_event, event: other_event)

      delete "/api/v1/events/#{other_event.id}/participants/#{elsewhere.id}", headers: headers
      expect(response).to have_http_status(:forbidden)

      delete "/api/v1/events/#{event.id}/participants/#{participant_event.id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(ParticipantEvent.exists?(participant_event.id)).to be(false)
    end
  end
end
