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

    # Slack ID lookups belong to the support bot, which holds a global token
    # scoped to support:read.
    def support_headers
      @support_token ||= GlobalApiToken.generate_for(admin, scopes: [ "support:read" ]).token
      { "Authorization" => "Bearer #{@support_token}" }
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

    it "requires an email or Slack ID" do
      get "/api/v1/events/#{event.id}/participants/lookup", headers: api_key_headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "finds a registration by the Slack ID Hack Club Auth verified, with its admin link" do
      user = create(:user, oidc_claims: { "slack_id" => "U0TESTPART" })
      participant = create(:participant, user: user)
      pe = create(:participant_event, participant: participant, event: event)

      get "/api/v1/events/#{event.id}/participants/lookup",
        params: { slack_id: " u0testpart " }, headers: support_headers

      body = JSON.parse(response.body)
      expect(body["registered"]).to be(true)
      expect(body["participant_id"]).to eq(participant.id)
      expect(body["participant_event_id"]).to eq(pe.id)
      expect(body["admin_url"]).to end_with("/admin/events/#{event.slug}/participants/#{pe.id}")
      expect(body["slack_id"]).to eq("U0TESTPART")
      expect(body["email"]).to be_nil
    end

    # Anyone can type any ID into a profile or registration; only Hack Club
    # Auth's counts.
    it "ignores Slack IDs typed onto the participant or registration" do
      create(:participant_event, event: event, participant: create(:participant, slack_user_id: "U0TESTPART"))
      create(:participant_event, event: event, slack_user_id: "U0TESTPART")

      get "/api/v1/events/#{event.id}/participants/lookup",
        params: { slack_id: "U0TESTPART" }, headers: support_headers

      expect(JSON.parse(response.body)["registered"]).to be(false)
    end

    it "refuses to guess when several registrations share a Slack ID" do
      2.times do
        user = create(:user, oidc_claims: { "slack_id" => "U0TESTPART" })
        create(:participant_event, event: event, participant: create(:participant, user: user))
      end

      get "/api/v1/events/#{event.id}/participants/lookup",
        params: { slack_id: "U0TESTPART" }, headers: support_headers

      expect(response).to have_http_status(:conflict)
    end

    context "when the caller isn't the support bot" do
      let(:series) { create(:event_series, name: "Moonbeam Series", slug: "moonbeam-lookup-api") }
      let(:series_owner) do
        User.create!(email: "moonbeam-owner@example.com", name: "Moonbeam Owner").tap do |user|
          SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
        end
      end

      before do
        event.update!(event_series: series)
        user = create(:user, oidc_claims: { "slack_id" => "U0TESTPART" })
        create(:participant_event, event: event, participant: create(:participant, user: user))
      end

      {
        "a legacy event API key" => -> { { "Authorization" => "Bearer #{api_key}" } },
        "an event API token" => -> {
          { "Authorization" => "Bearer #{EventApiToken.generate_for(event, user: series_owner, name: 'lookup').token}" }
        },
        "a series API token" => -> {
          { "Authorization" => "Bearer #{SeriesApiToken.generate_for(series, user: series_owner, name: 'lookup').token}" }
        },
        "a signed-in global admin on the mobile app" => -> { auth_headers }
      }.each do |caller, headers|
        it "refuses a Slack ID lookup from #{caller}" do
          get "/api/v1/events/#{event.id}/participants/lookup",
            params: { slack_id: "U0TESTPART" }, headers: instance_exec(&headers)

          expect(response).to have_http_status(:forbidden)
          expect(JSON.parse(response.body)["error"]).to include("support:read")
        end

        it "still answers an email lookup from #{caller}" do
          get "/api/v1/events/#{event.id}/participants/lookup",
            params: { email: "stranger@example.com" }, headers: instance_exec(&headers)

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["registered"]).to be(false)
        end
      end
    end

    it "lets an unrestricted global token look up by Slack ID, as it can every support endpoint" do
      user = create(:user, oidc_claims: { "slack_id" => "U0TESTPART" })
      create(:participant_event, event: event, participant: create(:participant, user: user))
      token = GlobalApiToken.generate_for(admin).token

      get "/api/v1/events/#{event.id}/participants/lookup",
        params: { slack_id: "U0TESTPART" }, headers: { "Authorization" => "Bearer #{token}" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["registered"]).to be(true)
    end

    # Only one key is ever matched on, so echoing both would claim a match the
    # lookup never checked.
    it "rejects an email and a Slack ID sent together" do
      participant = create(:participant, email: "voter@example.com")
      create(:participant_event, participant: participant, event: event)

      get "/api/v1/events/#{event.id}/participants/lookup",
        params: { email: "voter@example.com", slack_id: "U0SOMEONEELSE" }, headers: support_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Send email or slack_id, not both")
    end

    # Both lookup queries go through @event.participant_events, so Rails'
    # automatic inverse hands each registration @event and the admin link's
    # slug costs nothing. A scope or option on that association would quietly
    # break the inverse; this catches it.
    it "builds the admin link from the event it already loaded" do
      participant = create(:participant, email: "voter@example.com")
      pe = create(:participant_event, participant: participant, event: event)
      headers = api_key_headers

      event_selects = []
      counter = lambda do |*, payload|
        event_selects << payload[:sql] if payload[:sql].match?(/\ASELECT .* FROM "events"/)
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get "/api/v1/events/#{event.id}/participants/lookup", params: { email: "voter@example.com" }, headers: headers
      end

      expect(JSON.parse(response.body)["admin_url"]).to end_with("/admin/events/#{event.slug}/participants/#{pe.id}")
      # The legacy key resolves its event, then set_event loads it from the URL.
      # Building the admin link must not add a third.
      expect(event_selects.size).to eq(2), event_selects.join("\n")
    end

    it "is reachable by a global token scoped to support:read" do
      token = GlobalApiToken.generate_for(admin, scopes: [ "support:read" ]).token
      headers = { "Authorization" => "Bearer #{token}" }

      get "/api/v1/events/#{event.id}/participants/lookup", params: { email: "stranger@example.com" }, headers: headers
      expect(response).to have_http_status(:ok)

      get "/api/v1/events/#{event.id}/participants", headers: headers
      expect(response).to have_http_status(:forbidden)
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

    it "puts the invitee on the roster as invited, reusing a person who already exists" do
      existing = create(:participant, email: "Returning@Example.com", legal_first_name: "Rey", legal_last_name: "Turner")

      post "/api/v1/events/#{event.id}/participants",
        params: { email: "returning@example.com" }, headers: sign_in_headers_for("event_admin")

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["participant_id"]).to eq(existing.id)
      expect(body["status"]).to eq("invited")

      pe = ParticipantEvent.find(body["participant_event_id"])
      expect(pe.participant).to eq(existing)
      expect(pe).to be_invited
      # Reused, not forked into a second person by the case difference.
      expect(Participant.where("LOWER(email) = ?", "returning@example.com").count).to eq(1)
      expect(existing.reload.legal_first_name).to eq("Rey")
    end

    it "creates the person with replaceable placeholder names when none are sent" do
      post "/api/v1/events/#{event.id}/participants",
        params: { email: "nameless@example.com" }, headers: sign_in_headers_for("event_admin")

      expect(response).to have_http_status(:created)
      participant = Participant.find(JSON.parse(response.body)["participant_id"])
      # "Unknown" is what OnboardingController#backfill_participant_from_oidc
      # overwrites on first sign-in.
      expect(participant.legal_first_name).to eq("Unknown")
      expect(participant.legal_last_name).to eq("Unknown")
    end

    it "uses the names it was sent" do
      post "/api/v1/events/#{event.id}/participants",
        params: { email: "named@example.com", first_name: "Ada", last_name: "Lovelace" },
        headers: sign_in_headers_for("event_admin")

      participant = Participant.find(JSON.parse(response.body)["participant_id"])
      expect(participant.legal_first_name).to eq("Ada")
      expect(participant.legal_last_name).to eq("Lovelace")
    end

    it "creates the registration even while the event holds its invitations, leaving the wizard shut" do
      event.update!(onboarding_invites_held: true)

      expect {
        post "/api/v1/events/#{event.id}/participants",
          params: { email: "held@example.com" }, headers: sign_in_headers_for("event_admin")
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["held"]).to be(true)

      pe = ParticipantEvent.find(body["participant_event_id"])
      expect(pe).to be_invited
      expect(pe.onboarding_held?).to be(true)
    end

    it "makes the invitee reachable by broadcast once their invitation has gone out" do
      post "/api/v1/events/#{event.id}/participants",
        params: { email: "reachable@example.com" }, headers: sign_in_headers_for("event_admin")
      pe = ParticipantEvent.find(JSON.parse(response.body)["participant_event_id"])
      perform_enqueued_jobs # the mailer is what stamps the invitation as sent

      incomplete = Message.new(event: event, audience: "attendees_incomplete", channels: [ "email" ], sent_by_user: admin)
      everyone = Message.new(event: event, audience: "all_attendees", channels: [ "email" ], sent_by_user: admin)

      expect(incomplete.recipients).to include(pe)
      expect(everyone.recipients).to include(pe)
    end

    it "keeps a held invitee out of All Attendees until their invitation is released" do
      event.update!(onboarding_invites_held: true)

      post "/api/v1/events/#{event.id}/participants",
        params: { email: "quiet@example.com" }, headers: sign_in_headers_for("event_admin")
      pe = ParticipantEvent.find(JSON.parse(response.body)["participant_event_id"])

      everyone = Message.new(event: event, audience: "all_attendees", channels: [ "email" ], sent_by_user: admin)
      expect(everyone.recipients).not_to include(pe)

      # Releasing the hold sends the held invitations, which is what admits
      # them to the audience. Two drains: the release job enqueues the mailer,
      # and it is the mailer that stamps the invitation as sent.
      event.release_onboarding_invites!
      2.times { perform_enqueued_jobs }

      expect(everyone.recipients).to include(pe)
    end

    it "writes neither the invitation nor the registration when the registration cannot be created" do
      allow(ParticipantEvent).to receive(:create_with).and_raise(ActiveRecord::RecordInvalid.new(ParticipantEvent.new))

      expect {
        post "/api/v1/events/#{event.id}/participants",
          params: { email: "doomed@example.com" }, headers: sign_in_headers_for("event_admin")
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Invitation.where(event: event).for_email("doomed@example.com")).to be_empty
      expect(Participant.where(email: "doomed@example.com")).to be_empty
    end

    it "does not email a registration link when a real validation rejects the registration" do
      # Someone already on file whose Slack ID is banned: the email check up
      # front passes, and ParticipantEvent#participant_not_banned fails the
      # roster entry after the invitation row has been written inside the
      # same transaction.
      create(:participant, email: "slack-banned@example.com", slack_user_id: "UBANNED1")
      ban = build(:ban, email: "someone-else@example.com")
      ban.ban_slack_ids.build(slack_id: "UBANNED1")
      ban.save!

      post "/api/v1/events/#{event.id}/participants",
        params: { email: "slack-banned@example.com" }, headers: sign_in_headers_for("event_admin")
      expect(response).to have_http_status(:unprocessable_entity)

      # The mailer find-or-creates the invitation, so a job that survived the
      # rollback would resurrect it and send the link the API said it hadn't.
      perform_enqueued_jobs
      expect(Invitation.where(event: event).for_email("slack-banned@example.com")).to be_empty
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    # Signup forms see typos. Onboarding holds them until staff correct it
    # (spec/requests/onboarding_age_limit_spec.rb).
    it "invites someone whose birthday ages them out, keeping the birthday" do
      birthday = event.ends_at.to_date - 25.years

      post "/api/v1/events/#{event.id}/participants",
        params: { email: "typo@example.com", date_of_birth: birthday.iso8601 }, headers: sign_in_headers_for("event_admin")

      expect(response).to have_http_status(:created)
      participant = Participant.find_by!(email: "typo@example.com")
      expect(participant.date_of_birth).to eq(birthday)
      expect(event.participant_events.find_by!(participant: participant)).to be_too_old_for_event
    end

    it "invites someone already on file whose birthday ages them out" do
      create(:participant, email: "aged-out@example.com", date_of_birth: event.ends_at.to_date - 25.years)

      post "/api/v1/events/#{event.id}/participants",
        params: { email: "aged-out@example.com" }, headers: sign_in_headers_for("event_admin")

      expect(response).to have_http_status(:created)
    end

    it "409s for someone already registered under another casing of the address" do
      participant = create(:participant, email: "Done@Example.com")
      create(:participant_event, participant: participant, event: event, status: :complete)

      expect {
        post "/api/v1/events/#{event.id}/participants",
          params: { email: "done@example.com" }, headers: sign_in_headers_for("event_admin")
      }.to not_change(Invitation, :count).and not_change(ParticipantEvent, :count)

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to eq("This email is already registered for this event")
    end

    it "attaches to the oldest of duplicate participant rows for an address" do
      # Duplicate rows for one address are a known production state; the pick
      # must not vary from one invitation to the next.
      oldest = create(:participant, email: "dupe@example.com", created_at: 2.days.ago)
      create(:participant, email: "Dupe@Example.com", created_at: 1.day.ago)

      post "/api/v1/events/#{event.id}/participants",
        params: { email: "dupe@example.com" }, headers: sign_in_headers_for("event_admin")

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["participant_id"]).to eq(oldest.id)
    end

    it "409s on a second invitation rather than a duplicate registration" do
      headers = sign_in_headers_for("event_admin")
      post "/api/v1/events/#{event.id}/participants", params: { email: "twice@example.com" }, headers: headers
      expect(response).to have_http_status(:created)

      expect {
        post "/api/v1/events/#{event.id}/participants", params: { email: "twice@example.com" }, headers: headers
      }.not_to change(ParticipantEvent, :count)

      expect(response).to have_http_status(:conflict)
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

  describe "POST /api/v1/events/:event_id/participants with details" do
    let(:event_token) { EventApiToken.generate_for(event, user: create(:user), name: "integration") }

    def invite(params)
      post "/api/v1/events/#{event.id}/participants", params: params,
        headers: { "Authorization" => "Bearer #{event_token.token}" }
    end

    it "records the birthday, phone and country sent with the invitation" do
      invite(email: "detailed@example.com", first_name: "Dana", last_name: "Lee",
        date_of_birth: "2009-04-02", phone: "+1 202 555 0143", country: "US")

      expect(response).to have_http_status(:created)
      participant = Participant.find(JSON.parse(response.body)["participant_id"])
      expect(participant).to have_attributes(
        legal_first_name: "Dana", date_of_birth: Date.new(2009, 4, 2),
        phone: "+12025550143", country_of_residence: "United States"
      )
    end

    it "records a preferred name sent with the invitation" do
      invite(email: "preferred@example.com", first_name: "Daniel", last_name: "Lee", preferred_name: "Dana")

      expect(response).to have_http_status(:created)
      participant = Participant.find(JSON.parse(response.body)["participant_id"])
      expect(participant).to have_attributes(legal_first_name: "Daniel", preferred_name: "Dana")
    end

    it "accepts a country by name" do
      invite(email: "named-country@example.com", country: "united kingdom")

      expect(Participant.find(JSON.parse(response.body)["participant_id"]).country_of_residence).to eq("United Kingdom")
    end

    it "only fills in what a returning person is missing" do
      existing = create(:participant, email: "back@example.com", legal_first_name: "Unknown", legal_last_name: "Okafor",
        date_of_birth: nil, phone: "+12025550100")

      invite(email: "back@example.com", first_name: "Ada", last_name: "Changed",
        date_of_birth: "2008-01-31", phone: "+12025550199")

      expect(response).to have_http_status(:created)
      expect(existing.reload).to have_attributes(
        legal_first_name: "Ada", legal_last_name: "Okafor",
        date_of_birth: Date.new(2008, 1, 31), phone: "+12025550100"
      )
    end

    it "logs what it fills in on a returning person's record" do
      existing = create(:participant, email: "logged@example.com", date_of_birth: nil)

      invite(email: "logged@example.com", date_of_birth: "2008-01-31")

      expect(response).to have_http_status(:created)
      log = AuditLog.record_update.find_by(record: existing)
      expect(log).to be_present
      expect(log.event).to eq(event)
      expect(log.changed_fields.keys).to include("date_of_birth")
    end

    it "leaves a returning person's record alone when there's nothing to fill in" do
      existing = create(:participant, email: "complete@example.com", date_of_birth: Date.new(2008, 1, 31))
      # An older record that wouldn't pass today's validations.
      existing.update_columns(phone: "12345")

      invite(email: "complete@example.com", date_of_birth: "2009-04-02")

      expect(response).to have_http_status(:created)
      expect(existing.reload.date_of_birth).to eq(Date.new(2008, 1, 31))
      expect(AuditLog.record_update.where(record: existing)).not_to exist
    end

    it "rejects a birthday that isn't a date" do
      expect {
        invite(email: "bad-date@example.com", date_of_birth: "02/04/2009")
      }.not_to change(Invitation, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("YYYY-MM-DD")
    end

    it "rejects a country it doesn't know" do
      invite(email: "narnia@example.com", country: "Narnia")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("Narnia")
    end

    it "rejects an invalid phone number without inviting" do
      expect {
        invite(email: "bad-phone@example.com", phone: "12345")
      }.not_to change(Invitation, :count)

      expect(response).to have_http_status(:unprocessable_entity)
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

    it "sets the country from a code or a name" do
      patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
        params: { participant: { country_of_residence: "ca" } }, headers: api_key_headers

      expect(response).to have_http_status(:ok)
      expect(participant.reload.country_of_residence).to eq("Canada")

      patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
        params: { participant: { country_of_residence: "Atlantis" } }, headers: api_key_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(participant.reload.country_of_residence).to eq("Canada")
    end

    describe "fill_blanks" do
      before { participant.update!(legal_last_name: "Unknown", date_of_birth: nil, country_of_residence: nil) }

      it "only writes fields the participant has no value for, and says which it skipped" do
        patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
          params: {
            fill_blanks: true,
            participant: {
              legal_first_name: "Overwritten", legal_last_name: "Backfilled",
              date_of_birth: "2008-06-01", phone: "+12025550188", country_of_residence: "US"
            }
          },
          headers: api_key_headers

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["skipped_fields"]).to contain_exactly("legal_first_name", "phone")
        expect(participant.reload).to have_attributes(
          legal_first_name: "Robin", legal_last_name: "Backfilled", date_of_birth: Date.new(2008, 6, 1),
          phone: "+12025550100", country_of_residence: "United States"
        )
      end

      it "succeeds without writing when everything sent is already filled in" do
        patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
          params: { fill_blanks: true, participant: { legal_first_name: "Other" } }, headers: api_key_headers

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["skipped_fields"]).to eq([ "legal_first_name" ])
        expect(participant.reload.legal_first_name).to eq("Robin")
      end
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

    it "redacts the encrypted phone from the audit log like the web path does" do
      patch "/api/v1/events/#{event.id}/participants/#{participant_event.id}",
        params: { participant: { phone: "+12025550199", preferred_name: "Rob" } }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      log = AuditLog.find_by(action: "update", record: participant)
      expect(log.changed_fields["phone"]).to eq("[REDACTED]")
      expect(log.changed_fields["preferred_name"]).to eq([ nil, "Rob" ])
      expect(log.changed_fields.to_json).not_to include("2025550199")
      expect(log.changed_fields.to_json).not_to include("2025550100")
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

    it "revokes the invitation, so the old link cannot re-create the registration" do
      participant = create(:participant, email: "removed@example.com", user: create(:user, email: "removed@example.com"))
      create(:invitation, event: event, email: "removed@example.com", sent_at: Time.current)
      pe = create(:participant_event, participant: participant, event: event, status: :complete)

      expect {
        delete "/api/v1/events/#{event.id}/participants/#{pe.id}", headers: auth_headers
      }.to change(Invitation, :count).by(-1)

      expect(response).to have_http_status(:no_content)
      # The route that previously re-registered them: no surviving invitation,
      # so OnboardingController has nothing to rebuild from.
      expect(Invitation.where(event: event).for_email("removed@example.com")).to be_empty
    end

    it "records how many invitations it revoked in the audit log" do
      participant = create(:participant, email: "audited@example.com")
      create(:invitation, event: event, email: "audited@example.com", sent_at: Time.current)
      pe = create(:participant_event, participant: participant, event: event)

      delete "/api/v1/events/#{event.id}/participants/#{pe.id}", headers: auth_headers

      expect(AuditLog.last.metadata["invitations_revoked"]).to eq(1)
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
