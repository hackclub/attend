require "rails_helper"

RSpec.describe "Admin waiver dates banner", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-waiver-banner@example.com", name: "Admin", global_role: "global_admin") }
  let(:organizer) { User.create!(email: "organizer-waiver-banner@example.com", name: "Organizer") }
  let(:local_organizer) { User.create!(email: "local-waiver-banner@example.com", name: "Local Organizer") }
  let(:event) { create(:event) }

  before do
    create(:event_role_assignment, user: organizer, event: event, role: "event_admin")
    create(:event_role_assignment, user: local_organizer, event: event, role: "limited")
  end

  context "when the event's waivers have stale dates" do
    before { event.update_columns(waiver_dates_stale_since: Time.current) }

    it "offers organizers who manage templates the regeneration, without the dismiss button" do
      sign_in organizer
      get admin_event_dashboard_path(event)

      expect(response.body).to include("Waivers still show the old dates")
      expect(response.body).to include(new_admin_event_waiver_regeneration_path(event))
      expect(response.body).not_to include(clear_waiver_dates_warning_admin_event_path(event))
    end

    it "tells staff who can't regenerate to reach out" do
      sign_in local_organizer
      get admin_event_dashboard_path(event)

      expect(response.body).to include("Reach out to Attend team to get waivers updated")
      expect(response.body).not_to include(new_admin_event_waiver_regeneration_path(event))
    end

    it "lets global admins clear it" do
      sign_in admin
      get admin_event_dashboard_path(event)
      expect(response.body).to include(clear_waiver_dates_warning_admin_event_path(event))

      patch clear_waiver_dates_warning_admin_event_path(event)
      expect(event.reload).not_to be_waiver_dates_stale
    end

    it "doesn't let organizers clear it" do
      sign_in organizer
      patch clear_waiver_dates_warning_admin_event_path(event)

      expect(event.reload).to be_waiver_dates_stale
    end
  end

  it "shows no banner normally" do
    sign_in organizer
    get admin_event_dashboard_path(event)

    expect(response.body).not_to include("Reach out to Attend team")
  end
end
