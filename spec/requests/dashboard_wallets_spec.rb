require "rails_helper"

RSpec.describe "Dashboard wallet passes", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user) }
  let(:participant_event) { create(:participant_event, participant: participant, status: :complete) }

  before { sign_in user }

  it "hides the Apple Wallet action when Passkit is not configured" do
    web_service_host = ENV.delete("PASSKIT_WEB_SERVICE_HOST")

    get dashboard_event_path(participant_event)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Add to Apple Wallet")
    expect(response.body).to include("Add to Google Wallet")
  ensure
    ENV["PASSKIT_WEB_SERVICE_HOST"] = web_service_host
  end
end
