require "rails_helper"

RSpec.describe "Admin::Integrations Airtable sync status", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:global_admin) { User.create!(email: "ga-airtable@example.com", name: "Global Admin", global_role: "global_admin") }

  def configured_event(**attrs)
    create(
      :event,
      airtable_sync_source_id: "sncTest",
      airtable_sync_table_id: "tblTest",
      config: { "airtable_api_key" => "key-test", "airtable_base_id" => "app-test" },
      **attrs
    )
  end

  before { sign_in global_admin }

  it "warns that the sync is failing when the last success falls behind" do
    event = configured_event(airtable_synced_at: 3.hours.ago)

    get admin_event_integrations_path(event)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Stale")
    expect(response.body).to include("Sync is failing")
  end

  it "shows a healthy sync as active" do
    event = configured_event(airtable_synced_at: 2.minutes.ago)

    get admin_event_integrations_path(event)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Active")
    expect(response.body).not_to include("Sync is failing")
  end
end
