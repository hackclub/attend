require "rails_helper"

RSpec.describe "Api::V1::Notes", type: :request do
  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }

  def headers_for(user)
    { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" }
  end

  it "answers read-only staff with a JSON 403 instead of raising", :raise_exceptions do
    staff = create(:user)
    EventRoleAssignment.create!(user: staff, event: event, role: "read_only")

    get "/api/v1/events/#{event.id}/participants/#{participant_event.id}/notes", headers: headers_for(staff)

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)).to eq("error" => "Forbidden")
  end

  it "lists notes for ops staff" do
    staff = create(:user)
    EventRoleAssignment.create!(user: staff, event: event, role: "ops")

    get "/api/v1/events/#{event.id}/participants/#{participant_event.id}/notes", headers: headers_for(staff)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["notes"]).to eq([])
  end
end
