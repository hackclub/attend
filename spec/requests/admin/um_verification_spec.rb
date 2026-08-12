require "rails_helper"

RSpec.describe "Admin UM verification", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:admin) { User.create!(email: "ga-um@example.com", name: "Global Admin", global_role: "global_admin") }
  let(:participant_event) { create(:participant_event, event: event, um_status: :pending) }

  before do
    participant_event.travels.create!(direction: "inbound", mode: "plane", is_unaccompanied_minor: true)
    sign_in admin
  end

  it "approves UM status and stamps the reviewer" do
    post approve_um_admin_event_participant_path(event.slug, participant_event)

    expect(response).to redirect_to(travel_admin_event_participant_path(event.slug, participant_event))
    participant_event.reload
    expect(participant_event).to be_um_approved
    expect(participant_event.um_verified_by).to eq(admin)
    expect(participant_event.verified_unaccompanied_minor?).to be true
  end

  it "rejects UM status" do
    post reject_um_admin_event_participant_path(event.slug, participant_event)

    participant_event.reload
    expect(participant_event).to be_um_rejected
    expect(participant_event.verified_unaccompanied_minor?).to be false
  end

  it "shows the verification panel on the travel page" do
    get travel_admin_event_participant_path(event.slug, participant_event)

    expect(response.body).to include("Unaccompanied Minor Verification")
    expect(response.body).to include("Pending review")
  end

  it "redirects from um_proof with an alert when nothing is uploaded" do
    get um_proof_admin_event_participant_path(event.slug, participant_event)

    expect(response).to redirect_to(travel_admin_event_participant_path(event.slug, participant_event))
    expect(flash[:alert]).to include("No UM proof uploaded")
  end
end
