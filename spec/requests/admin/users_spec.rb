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
end
