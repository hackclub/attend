require "rails_helper"

RSpec.describe "Dashboard letters", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user, date_of_birth: 18.years.ago - 1.day) }
  let(:registration) do
    create(:participant_event, participant: participant, status: :complete, code_of_conduct_accepted_at: Time.current).tap do |registration|
      create(:consent, :signed, participant_event: registration)
    end
  end

  before { sign_in user }

  it "offers the school excuse letter and the invitation letter with the entry ticket" do
    get dashboard_event_path(registration)

    expect(response.body).to include(dashboard_download_excuse_letter_path(registration), dashboard_download_invitation_letter_path(registration))

    get dashboard_download_invitation_letter_path(registration)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Content-Disposition"]).to include("invitation-letter.pdf")
  end

  it "only gives an invitation letter once the registration is complete" do
    registration.update!(status: :in_progress)

    get dashboard_download_invitation_letter_path(registration)

    expect(response).to redirect_to(dashboard_path)
    expect(flash[:alert]).to eq("Your invitation letter is available once your registration is complete.")
  end
end
