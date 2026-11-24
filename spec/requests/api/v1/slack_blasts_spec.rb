require "rails_helper"

RSpec.describe "Api::V1::SlackBlasts", type: :request do
  let(:event) { create(:event) }
  let(:viewer) { create(:user) }

  before { create(:event_role_assignment, user: viewer, event: event, role: "read_only") }

  def headers
    { "Authorization" => "Bearer #{MobileToken.generate_for(viewer).token}" }
  end

  it "lets read-only staff list blasts but not send one" do
    get "/api/v1/events/#{event.id}/slack_blasts", headers: headers
    expect(response).to have_http_status(:ok)

    expect {
      post "/api/v1/events/#{event.id}/slack_blasts", params: { message: "Doors open" }, headers: headers, as: :json
    }.not_to change(SlackBlast, :count)
    expect(response).to have_http_status(:forbidden)
  end
end
