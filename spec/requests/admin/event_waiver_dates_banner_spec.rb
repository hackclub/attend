require "rails_helper"

RSpec.describe "Admin waiver dates banner", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-waiver-banner@example.com", name: "Admin", global_role: "global_admin") }
  let(:organizer) { User.create!(email: "organizer-waiver-banner@example.com", name: "Organizer") }
  let(:event) { create(:event) }

  before do
    create(:event_role_assignment, user: organizer, event: event, role: "event_admin")
  end

  context "when the event's waivers have stale dates" do
    before { event.update_columns(waiver_dates_stale_since: Time.current) }

    it "shows organizers the banner without the clear button" do
      sign_in organizer
      get admin_event_dashboard_path(event)

      expect(response.body).to include("Reach out to Attend team to get waivers updated")
      expect(response.body).not_to include("Waivers updated")
    end

    it "lets global admins clear it" do
      sign_in admin
      get admin_event_dashboard_path(event)
      expect(response.body).to include("Waivers updated")

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
