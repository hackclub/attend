require "rails_helper"

RSpec.describe "Admin::Groups", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-groups@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event, config: { "groups_enabled" => "1" }) }

  before { sign_in admin }

  describe "GET index" do
    it "renders the groups for the event in the URL" do
      group = create(:group, event: event, name: "Hardware Cohort")

      get admin_event_groups_path(event_slug: event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(group.name)
    end

    it "returns 404 when groups are disabled for the event" do
      disabled_event = create(:event)

      get admin_event_groups_path(event_slug: disabled_event.slug)

      expect(response).to have_http_status(:not_found)
    end

    it "uses the URL event when the session points at a different event" do
      other_event = create(:event)
      post select_admin_event_path(other_event.slug)

      group = create(:group, event: event, name: "URL Event Group")
      get admin_event_groups_path(event_slug: event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(group.name)
    end

    it "returns 404 for a disabled URL event even when the session event has groups enabled" do
      post select_admin_event_path(event.slug)
      disabled_event = create(:event)

      get admin_event_groups_path(event_slug: disabled_event.slug)

      expect(response).to have_http_status(:not_found)
    end
  end
end
