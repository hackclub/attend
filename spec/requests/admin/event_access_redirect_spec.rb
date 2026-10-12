require "rails_helper"

# Admin::BaseController sends people back to the events list when their
# selected event is gone or they've lost access to it. That target used to be
# admin_events_path, which only exists for POST (create), so the redirect
# landed on a routing error instead of the list with an alert.
RSpec.describe "Admin event access redirects", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:user) { User.create!(email: "lost-access-spec@example.com", name: "Lost Access") }

  it "returns someone who lost access to their selected event to the events list" do
    assignment = EventRoleAssignment.create!(user: user, event: event, role: "event_admin")
    # Still staff on another event, so the general admin gate lets them in.
    EventRoleAssignment.create!(user: user, event: create(:event), role: "event_admin")
    sign_in user
    post select_admin_event_path(event)
    assignment.destroy!

    get admin_root_path

    expect(response).to redirect_to(admin_root_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("You no longer have access to that event.")
  end
end
