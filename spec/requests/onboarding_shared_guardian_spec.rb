require "rails_helper"

# One Guardian row serves every registration that names it, so onboarding may
# only rewrite a row that belongs to this registration alone.
RSpec.describe "Onboarding and shared guardian rows", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, travel_enabled: false, accommodation_enabled: false) }
  let(:guardian) { create(:guardian, legal_first_name: "Grace", email: "grace@example.com", phone: "+12025550100") }
  let!(:other_link) { create(:guardian_participant_event, guardian: guardian, participant_event: create(:participant_event, event: event)) }

  let(:user) { create(:user) }
  let(:participant_event) do
    participant = create(:participant, user: user, email: user.email, date_of_birth: 15.years.ago.to_date)
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 99)
  end

  before do
    participant_event
    sign_in user
  end

  def submit_guardian(email: guardian.email, phone: "+12025550100", autosave: false)
    params = {
      guardian_first_name: "Grace", guardian_last_name: guardian.legal_last_name,
      guardian_email: email, guardian_phone: phone, guardian_relationship: "Parent"
    }
    params[:autosave] = "true" if autosave

    patch onboarding_step_path(step: "guardian", event_id: event.id), params: params
  end

  it "refuses to link with details that differ from the row on file" do
    submit_guardian(phone: "+12025550199")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(flash[:alert]).to include("already on file with different details")
    expect(guardian.reload.phone).to eq("+12025550100")
    expect(participant_event.guardian_participant_events).to be_empty
  end

  it "applies the same rule on autosave" do
    submit_guardian(phone: "+12025550199", autosave: true)

    expect(response).to have_http_status(:unprocessable_content)
    expect(guardian.reload.phone).to eq("+12025550100")
  end

  it "links a sibling whose details match without touching the row" do
    expect { submit_guardian(email: "GRACE@example.com") }
      .to change { participant_event.guardian_participant_events.count }.by(1)
      .and not_change { guardian.reload.updated_at }
  end

  it "does not rewrite a shared row that is already linked" do
    create(:guardian_participant_event, :never_sent, guardian: guardian, participant_event: participant_event)

    submit_guardian(email: "grace.new@example.com", phone: "+12025550199")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(guardian.reload.slice(:email, :phone)).to eq("email" => "grace@example.com", "phone" => "+12025550100")
  end

  it "locks the email on submit once access was issued, not only on autosave" do
    own = create(:guardian, email: "own@example.com")
    create(:guardian_participant_event, guardian: own, participant_event: participant_event)

    submit_guardian(email: "moved@example.com")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(own.reload.email).to eq("own@example.com")
  end
end
