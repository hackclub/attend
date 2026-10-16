require "rails_helper"

RSpec.describe "Onboarding accounts step", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:series) { create(:event_series, github_linking: "required", itch_linking: "optional") }
  let(:event) { create(:event, event_series: series, travel_enabled: false, accommodation_enabled: false) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user, email: user.email, date_of_birth: 18.years.ago - 1.month) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 3)
  end

  before do
    stub_account_linking_credentials
    sign_in user
  end

  def accounts_path
    onboarding_step_path(step: "accounts", event_id: event.id)
  end

  it "comes after the emergency contact and before documents" do
    get accounts_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Connect your accounts")
    expect(response.body).to include("Sign in with GitHub")
    expect(response.body).to include("Sign in with itch.io")
    expect(response.body).to include("Required")
    expect(response.body).to include("Optional")
  end

  it "holds Continue until required accounts are connected" do
    patch accounts_path

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Please connect your GitHub account to continue.")
    expect(participant_event.reload.onboarding_step).to eq(3)
  end

  it "lets the participant continue once required accounts are connected" do
    participant.connected_accounts.create!(provider: "github", uid: "1", username: "octocat", access_token: "t", connected_at: Time.current)

    patch accounts_path

    expect(response).to redirect_to(onboarding_step_path(step: "documents", event_id: event.id))
  end

  it "shows the connected account" do
    participant.connected_accounts.create!(provider: "github", uid: "1", username: "octocat", access_token: "t", connected_at: Time.current)

    get accounts_path

    expect(response.body).to include("octocat")
    expect(response.body).to include("Disconnect")
  end

  it "doesn't block on a provider that can't be connected yet" do
    stub_account_linking_credentials(github: false)

    patch accounts_path

    expect(response).to redirect_to(onboarding_step_path(step: "documents", event_id: event.id))
  end

  it "re-checks required accounts on submit" do
    participant_event.update!(onboarding_step: 99)

    post complete_onboarding_path(event_id: event.id), params: { code_of_conduct_accepted: "1", code_of_conduct_signature: "Me" }

    expect(response).to redirect_to(accounts_path)
    expect(participant_event.reload.code_of_conduct_accepted_at).to be_nil
  end

  context "when the series doesn't ask for accounts" do
    let(:series) { create(:event_series) }

    it "skips the step" do
      get accounts_path

      expect(response).to redirect_to(onboarding_path(event_id: event.id))
    end
  end
end
