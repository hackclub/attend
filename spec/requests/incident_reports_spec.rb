require "rails_helper"

RSpec.describe "Public incident form", type: :request do
  include Devise::Test::IntegrationHelpers

  let!(:event) { create(:event, name: "Example Camp", starts_at: 1.day.ago, ends_at: 1.day.from_now) }

  it "points organizers at their event's incident log" do
    organizer = create(:user, email: "organizer-public@example.com")
    EventRoleAssignment.create!(user: organizer, event: event, role: "ops")
    sign_in organizer

    get incident_report_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Organizing one of these events?", new_admin_event_incident_path(event))
  end

  it "says nothing about the log to a participant" do
    sign_in create(:user, email: "attendee-public@example.com")
    get incident_report_path
    expect(response.body).not_to include("Organizing one of these events?")
  end

  it "renders for signed-out visitors" do
    get incident_report_path
    expect(response).to have_http_status(:ok)
  end
end
