require "rails_helper"

RSpec.describe "Missing arrival window banner", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }
  let(:event) { create(:event) }

  before do
    sign_in admin
    get select_admin_event_path(slug: event.slug)
  end

  [ true, false ].each do |console|
    it "shows on every page of an event with no arrival window (#{console ? "console" : "original"})" do
      admin.update!(admin_console_beta: console)

      get admin_event_dashboard_path(event.slug)
      expect(response.body).to include('data-testid="arrival-window-banner"')
      expect(response.body).to include(edit_admin_event_path(event, anchor: "arrival-window"))

      get admin_event_staff_index_path(event_slug: event.slug)
      expect(response.body).to include('data-testid="arrival-window-banner"')
    end
  end

  [ true, false ].each do |console|
    it "stays off pages that aren't about any one event (#{console ? "console" : "original"})" do
      admin.update!(admin_console_beta: console)

      [ admin_root_path, admin_new_event_path, admin_users_path, admin_visa_letter_templates_path, admin_audit_logs_path ].each do |path|
        get path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('data-testid="arrival-window-banner"'), "expected no banner on #{path}"
      end
    end
  end

  it "shows on the event's own audit log" do
    get admin_audit_logs_path(event_id: event.id)

    expect(response.body).to include('data-testid="arrival-window-banner"')
  end

  it "goes away once either end of the window is set" do
    event.update!(arrival_closes_at: event.starts_at)

    get admin_event_dashboard_path(event.slug)

    expect(response.body).not_to include('data-testid="arrival-window-banner"')
  end

  it "doesn't nag about events that are already over" do
    event.update!(starts_at: 3.weeks.ago, ends_at: 2.weeks.ago)

    get admin_event_dashboard_path(event.slug)

    expect(response.body).not_to include('data-testid="arrival-window-banner"')
  end
end
