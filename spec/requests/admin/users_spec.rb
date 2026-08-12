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
  end
end
