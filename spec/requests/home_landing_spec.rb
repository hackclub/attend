require "rails_helper"

# Where signing in (or visiting /) lands someone, by what they can do.
RSpec.describe "Landing after sign-in", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }

  it "sends a series organizer with no role on any event to the admin" do
    organizer = create(:user)
    SeriesRoleAssignment.create!(user: organizer, event_series: create(:event_series), role: "organizer")
    sign_in organizer

    get root_path
    expect(response).to redirect_to(admin_root_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
  end

  it "sends event staff to the admin" do
    staff = create(:event_role_assignment, event: event, role: "ops").user
    sign_in staff

    get root_path
    expect(response).to redirect_to(admin_root_path)
  end

  # Read-only staff can't use the admin (User#admin? leaves them out), so
  # sending them there bounced them straight back to / and round again.
  it "doesn't send read-only staff into a redirect loop" do
    read_only = create(:event_role_assignment, event: event, role: "read_only").user
    sign_in read_only

    get root_path
    expect(response).to redirect_to(training_path)
  end

  it "leaves someone with nothing to do on the home page" do
    sign_in create(:user)

    get root_path
    expect(response).to have_http_status(:ok)
  end

  describe "signing in with Hack Club Auth" do
    around do |example|
      OmniAuth.config.test_mode = true
      example.run
    ensure
      OmniAuth.config.mock_auth[:hack_club] = nil
      OmniAuth.config.test_mode = false
    end

    it "lands a series organizer in the admin" do
      organizer = create(:user, email: "series-organizer@example.com", hack_club_account_id: "hca-example-1")
      SeriesRoleAssignment.create!(user: organizer, event_series: create(:event_series), role: "owner")
      OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(
        provider: "hack_club", uid: "hca-example-1",
        info: { email: "series-organizer@example.com", name: "Example Organizer" }
      )

      get "/users/auth/hack_club/callback"
      expect(response).to redirect_to(admin_root_path)
    end
  end
end
