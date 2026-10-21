require "rails_helper"

RSpec.describe "Admin::Users", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:global_admin) { User.create!(email: "ga-users@example.com", name: "Global Admin", global_role: "global_admin") }

  describe "GET index" do
    it "shows event role counts and attendee-ship separately" do
      event = create(:event)
      attendee = User.create!(email: "attendee@example.com", name: "Attendee Only")
      participant = create(:participant, user: attendee, email: attendee.email)
      ParticipantEvent.create!(participant: participant, event: event, status: "complete")

      sign_in global_admin
      get admin_users_path(search: "attendee@example.com")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("0 roles")
      expect(response.body).to include("Attendee at 1 event")
    end

    it "counts registrations held by a participant record with no account link" do
      # The shape a corrected import typo leaves behind: the person signed in
      # and got a bare participant row, while every registration sits on the
      # imported row whose email an admin fixed after the fact.
      event = create(:event)
      user = User.create!(email: "afnan@example.com", name: "Afnan")
      create(:participant, user: user, email: user.email)
      imported = create(:participant, user: nil, email: "Afnan@example.com")
      create(:participant_event, participant: imported, event: event, status: "invited")

      sign_in global_admin
      get admin_users_path(search: "afnan@example.com")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Attendee at 1 event")
      expect(response.body).to include("Unlinked participant record")
    end

    it "counts each registration once when the record is both linked and email-matched" do
      event = create(:event)
      user = User.create!(email: "single@example.com", name: "Single")
      participant = create(:participant, user: user, email: user.email)
      create(:participant_event, participant: participant, event: event, status: "complete")

      sign_in global_admin
      get admin_users_path(search: "single@example.com")

      expect(response.body).to include("Attendee at 1 event")
      expect(response.body).not_to include("Unlinked participant record")
    end

    it "omits the attendee line for users with no participant record" do
      sign_in global_admin
      get admin_users_path(search: "ga-users@example.com")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Attendee at")
    end

    it "surfaces matching participants who have never signed in" do
      event = create(:event, name: "Sunbeam Dhaka")
      participant = create(:participant, user: nil, email: "never-signed-in@example.com",
                           legal_first_name: "Never", legal_last_name: "Signedin")
      participant_event = create(:participant_event, participant: participant, event: event)

      sign_in global_admin
      get admin_users_path(search: "never-signed-in@example.com")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Participants without an account")
      expect(response.body).to include("never-signed-in@example.com")
      expect(response.body).to include("Sunbeam Dhaka")
      expect(response.body).to include(admin_event_participant_path(event, participant_event))
    end

    it "matches unlinked participants by name as well as email" do
      participant = create(:participant, user: nil, email: "anon@example.com",
                           legal_first_name: "Anusha", legal_last_name: "Ismat")
      create(:participant_event, participant: participant)

      sign_in global_admin
      get admin_users_path(search: "Anusha Ismat")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Participants without an account")
      expect(response.body).to include("anon@example.com")
    end

    it "does not list participants who already have a user account" do
      linked = User.create!(email: "linked@example.com", name: "Linked")
      participant = create(:participant, user: linked, email: linked.email)
      create(:participant_event, participant: participant)

      sign_in global_admin
      get admin_users_path(search: "linked@example.com")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Participants without an account")
    end

    it "does not list participants whose account exists but was never linked" do
      # Signing in creates the User; `participant.user_id` only gets filled in
      # once they start onboarding, so the two can co-exist unlinked.
      User.create!(email: "afnan@example.com", name: "Afnan")
      participant = create(:participant, user: nil, email: "Afnan@example.com")
      create(:participant_event, participant: participant)

      sign_in global_admin
      get admin_users_path(search: "afnan@example.com")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Participants without an account")
    end

    it "skips the participant fallthrough when filtering by role" do
      create(:participant, user: nil, email: "roleless@example.com")

      sign_in global_admin
      get admin_users_path(search: "roleless@example.com", role: "global_admin")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Participants without an account")
    end

    it "explains the empty result when nothing matches at all" do
      sign_in global_admin
      get admin_users_path(search: "nobody-at-all@example.com")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No user account matches")
      expect(response.body).not_to include("Participants without an account")
    end
  end

  describe "GET show" do
    def ban_alert_for(user)
      sign_in global_admin
      get admin_user_path(user)
      expect(response).to have_http_status(:ok)
      response.body.include?("user-ban-alert")
    end

    it "flags a user whose email is on an active ban" do
      user = User.create!(email: "flagged@example.com", name: "Flagged")
      ban = create(:ban, email: "Flagged@example.com", reason: "Conduct at a past event")

      expect(ban_alert_for(user)).to be(true)
      expect(response.body).to include("Conduct at a past event")
      expect(response.body).to include(admin_ban_path(ban))
    end

    it "flags a user whose participant record email is on an active ban" do
      user = User.create!(email: "account@example.com", name: "Account")
      create(:participant, user: user, email: "imported@example.com")
      create(:ban, email: "imported@example.com")

      expect(ban_alert_for(user)).to be(true)
    end

    it "only shows the identifiers that belong to this user" do
      user = User.create!(email: "one@example.com", name: "One")
      ban = Ban.new(reason: "Grouped case")
      ban.ban_emails.build(email: "one@example.com")
      ban.ban_emails.build(email: "other-address@example.com")
      ban.ban_slack_ids.build(slack_id: "U0NOTTHISUSER")
      ban.save!

      expect(ban_alert_for(user)).to be(true)
      alert = response.body[/data-testid="user-ban-alert".*?<\/(section|div)>/m]
      expect(alert).to include("matched on one@example.com")
      expect(alert).not_to include("other-address@example.com", "U0NOTTHISUSER")
    end

    it "does not dangle a UCAT case label when the ban has no stored cases" do
      user = User.create!(email: "legacy-ucat@example.com", name: "Legacy")
      create(:ban, email: "legacy-ucat@example.com", source: :ucat, external_key: "legacy-ucat@example.com")

      expect(ban_alert_for(user)).to be(true)
      expect(response.body).not_to include("UCAT case")
    end

    it "flags a user whose verified Slack ID is on an active ban" do
      user = User.create!(email: "slacker@example.com", name: "Slacker", oidc_claims: { "slack_id" => "U0SLACKBAN1" })
      ban = Ban.new(reason: "Slack ban")
      ban.ban_slack_ids.build(slack_id: "U0SLACKBAN1")
      ban.save!

      expect(ban_alert_for(user)).to be(true)
      expect(response.body).to include("Slack U0SLACKBAN1")
    end

    it "links a UCAT ban back to its Airtable cases" do
      user = User.create!(email: "ucat@example.com", name: "Ucat")
      create(:ban, email: "ucat@example.com", source: :ucat, external_key: "ucat@example.com",
        reason: "UCAT ban (case X9)", ucat_cases: [ { "id" => "X9", "record_id" => "recX9000000000000" } ])

      expect(ban_alert_for(user)).to be(true)
      expect(response.body).to include("https://airtable.com/#{Bans::UcatSync::BASE_ID}/#{Bans::UcatSync::TABLE_ID}/recX9000000000000")
      expect(response.body).to include(">X9<")
    end

    it "does not flag a user whose only ban is revoked" do
      user = User.create!(email: "revoked@example.com", name: "Revoked")
      create(:ban, email: "revoked@example.com").revoke!(by: global_admin)

      expect(ban_alert_for(user)).to be(false)
    end

    it "does not flag a user whose only ban has expired" do
      user = User.create!(email: "expired@example.com", name: "Expired")
      create(:ban, :expired, email: "expired@example.com")

      expect(ban_alert_for(user)).to be(false)
    end

    it "does not flag an unbanned user" do
      user = User.create!(email: "fine@example.com", name: "Fine")
      create(:ban, email: "someone-else@example.com")

      expect(ban_alert_for(user)).to be(false)
    end

    it "lists registrations held by an unlinked participant record and offers the merge" do
      event = create(:event, name: "Sunbeam Dhaka")
      user = User.create!(email: "afnan@example.com", name: "Afnan")
      shell = create(:participant, user: user, email: user.email)
      imported = create(:participant, user: nil, email: "Afnan@example.com")
      participant_event = create(:participant_event, participant: imported, event: event, status: "invited")

      sign_in global_admin
      get admin_user_path(user)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sunbeam Dhaka")
      expect(response.body).to include("isn't linked to this account")
      expect(response.body).to include(
        merge_admin_event_participant_path(event, participant_event, duplicate_id: shell.id)
      )
    end

    it "does not flag registrations on the account's own participant record" do
      event = create(:event, name: "Sunbeam Dallas")
      user = User.create!(email: "own@example.com", name: "Own")
      participant = create(:participant, user: user, email: user.email)
      create(:participant_event, participant: participant, event: event, status: "complete")

      sign_in global_admin
      get admin_user_path(user)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sunbeam Dallas")
      expect(response.body).not_to include("isn't linked to this account")
    end
  end
end
