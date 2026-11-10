require "rails_helper"

RSpec.describe "Admin search", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:participant) do
    create(:participant, legal_first_name: "Ada", legal_last_name: "Lovelace", slack_user_id: "U0TESTADA1")
  end
  let!(:participant_event) do
    create(:participant_event, event: event, participant: participant, slack_user_id: "U0TESTADA1")
  end

  # Event staff search through a join onto participant_events, which has its
  # own slack_user_id column, so an unqualified column name was ambiguous.
  it "finds a participant by Slack ID for event staff, whose search joins registrations" do
    user = User.create!(email: "search-staff@example.com", name: "Staff", admin_console_beta: false)
    EventRoleAssignment.create!(user: user, event: event, role: "ops")
    sign_in user

    get admin_search_path(q: "u0testada1"), headers: { "ACCEPT" => "application/json" }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["participants"].map { |p| p["id"] }).to eq([ participant_event.id ])
  end
end
