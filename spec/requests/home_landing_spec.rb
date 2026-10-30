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

  describe "someone who is both staff and a participant" do
    let(:past_event) { create(:event, starts_at: 3.weeks.ago, ends_at: 2.weeks.ago) }
    let(:user) { create(:user).tap { |u| create(:participant, user: u) } }

    it "sends them to their dashboard once every event they staffed has ended" do
      create(:event_role_assignment, event: past_event, user: user, role: "event_admin")
      sign_in user

      get root_path
      expect(response).to redirect_to(dashboard_path)
    end

    it "still sends them to the admin while an event they staff hasn't ended" do
      create(:event_role_assignment, event: past_event, user: user, role: "event_admin")
      create(:event_role_assignment, event: event, user: user, role: "ops")
      sign_in user

      get root_path
      expect(response).to redirect_to(admin_root_path)
    end

    it "still sends a series organizer to the admin" do
      SeriesRoleAssignment.create!(user: user, event_series: create(:event_series), role: "organizer")
      sign_in user

      get root_path
      expect(response).to redirect_to(admin_root_path)
    end
  end

  it "keeps sending staff of past events to the admin when they aren't a participant" do
    staff = create(:event_role_assignment, event: create(:event, starts_at: 3.weeks.ago, ends_at: 2.weeks.ago), role: "event_admin").user
    sign_in staff

    get root_path
    expect(response).to redirect_to(admin_root_path)
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

    it "only goes back to an origin that's a path on Attend" do
      create(:user, email: "returning@example.com", hack_club_account_id: "hca-example-2")
      OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(
        provider: "hack_club", uid: "hca-example-2", info: { email: "returning@example.com", name: "Example Person" }
      )

      [ "https://elsewhere.example/visas", "//elsewhere.example/visas", "/\\elsewhere.example" ].each do |origin|
        post user_hack_club_omniauth_authorize_path, params: { origin: origin }
        follow_redirect!
        expect(response.location).not_to include("elsewhere.example"), origin
      end

      post user_hack_club_omniauth_authorize_path, params: { origin: "/visas" }
      follow_redirect!
      expect(response).to redirect_to("/visas")
    end
  end
end
