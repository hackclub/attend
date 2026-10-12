require "rails_helper"

RSpec.describe "Onboarding guardian autosave", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, travel_enabled: false, accommodation_enabled: false) }
  let(:user) { create(:user) }
  # Factory participants are 16, so the guardian step is in the flow.
  let(:participant) { create(:participant, user: user) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 2)
  end

  before { sign_in user }

  def autosave(params)
    patch onboarding_step_path(step: "guardian", event_id: event.id),
          params: params.merge(autosave: "true")
  end

  let(:guardian_params) do
    {
      guardian_first_name: "Jane",
      guardian_last_name: "Guardian",
      guardian_email: "new-guardian@example.com",
      guardian_phone: "+12025559876",
      guardian_relationship: "Parent"
    }
  end

  it "creates the guardian and the link when the email is new" do
    expect { autosave(guardian_params) }
      .to change(Guardian, :count).by(1)
      .and change(GuardianParticipantEvent, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("success" => true)

    gpe = participant_event.reload.guardian_participant_events.first
    expect(gpe.relationship).to eq("Parent")
    expect(gpe.guardian).to have_attributes(
      legal_first_name: "Jane",
      legal_last_name: "Guardian",
      email: "new-guardian@example.com"
    )
  end

  it "links an existing guardian by email without creating a new one" do
    guardian = create(:guardian, email: "new-guardian@example.com")

    expect { autosave(guardian_params) }
      .to change(GuardianParticipantEvent, :count).by(1)
      .and not_change(Guardian, :count)

    expect(response).to have_http_status(:ok)
    expect(participant_event.reload.guardian_participant_events.first.guardian).to eq(guardian)
  end

  it "updates the already linked guardian on later autosaves" do
    autosave(guardian_params)

    expect { autosave(guardian_params.merge(guardian_first_name: "Janet", guardian_relationship: "Guardian")) }
      .to not_change(Guardian, :count)
      .and not_change(GuardianParticipantEvent, :count)

    expect(response).to have_http_status(:ok)
    gpe = participant_event.reload.guardian_participant_events.first
    expect(gpe.relationship).to eq("Guardian")
    expect(gpe.guardian.legal_first_name).to eq("Janet")
  end

  it "saves nothing when the new guardian is invalid" do
    expect { autosave(guardian_params.merge(guardian_last_name: "")) }
      .to not_change(Guardian, :count)
      .and not_change(GuardianParticipantEvent, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["success"]).to be(false)
    expect(response.parsed_body["errors"]).to include(a_string_including("Guardian: Legal last name can't be blank"))
  end
end
