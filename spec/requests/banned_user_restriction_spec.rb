require "rails_helper"

RSpec.describe "Banned user restriction", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user, email: "restricted@example.com") }

  before do
    create(:participant, user: user, email: user.email)
    sign_in user
  end

  it "shows the restriction page instead of the dashboard" do
    create(:ban, email: "restricted@example.com")

    get dashboard_profile_path

    expect(response).to have_http_status(:forbidden)
    expect(response.body).to include("restricted from attending Hack Club events", "attend@hackclub.com")
  end

  it "matches a ban on the participant's Slack ID" do
    user.participant.update!(slack_user_id: "U0RESTRICT")
    Ban.create!(ban_slack_ids: [ BanSlackId.new(slack_id: "U0RESTRICT") ])

    get dashboard_profile_path

    expect(response).to have_http_status(:forbidden)
  end

  it "lets the user through once the ban is revoked" do
    create(:ban, email: "restricted@example.com").revoke!

    get dashboard_profile_path

    expect(response).to have_http_status(:ok)
  end

  it "doesn't restrict staff" do
    user.update!(global_role: "global_admin")
    create(:ban, email: "restricted@example.com")

    get dashboard_profile_path

    expect(response).to have_http_status(:ok)
  end
end
