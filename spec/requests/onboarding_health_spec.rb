require "rails_helper"

RSpec.describe "Onboarding health sections", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user, date_of_birth: 15.years.ago) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 3)
  end

  before { sign_in user }

  def health_path
    onboarding_step_path(step: "health", event_id: event.id)
  end

  it "saves explicit section responses without requiring text" do
    patch health_path, params: {
      medical: { section_response: "nothing_to_add", has_anaphylaxis_risk: "0", requires_refrigeration: "0" },
      dietary: { section_response: "private", diet_type: "" },
      accessibility: { section_response: "details", has_adhd: "0", has_dyslexia: "0", has_autism: "0" }
    }

    expect(response).to have_http_status(:redirect)
    expect(participant_event.reload.medical.section_response).to eq("nothing_to_add")
    expect(participant_event.dietary.section_response).to eq("private")
    expect(participant_event.accessibility.section_response).to eq("details")
  end

  it "persists the complete medical and accessibility field set" do
    patch health_path, params: {
      medical: {
        section_response: "details", allergy_severity: "severe",
        emergency_action_plan: "Call emergency services", additional_notes: "Carry spare medication"
      },
      dietary: { section_response: "nothing_to_add" },
      accessibility: {
        section_response: "details", light_sensitivity: "1", prayer_space_required: "1",
        religious_practices: "Daily prayer", distance_limitations: "Avoid long walks",
        unavailable_times: "Friday afternoon"
      }
    }

    expect(response).to have_http_status(:redirect)
    expect(participant_event.reload.medical).to have_attributes(
      allergy_severity: "severe", emergency_action_plan: "Call emergency services",
      additional_notes: "Carry spare medication"
    )
    expect(participant_event.accessibility).to have_attributes(
      light_sensitivity: true, prayer_space_required: true,
      religious_practices: "Daily prayer", distance_limitations: "Avoid long walks",
      unavailable_times: "Friday afternoon"
    )
  end

  it "normalizes placeholders during autosave and persists the cleared value" do
    medical = participant_event.create_medical!(allergies: "peanuts")

    patch health_path, params: {
      autosave: "true",
      medical: { section_response: "details", allergies: " N/A ", has_anaphylaxis_risk: "1" },
      dietary: { section_response: "nothing_to_add", diet_type: "" },
      accessibility: { section_response: "nothing_to_add" }
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("success" => true)
    expect(medical.reload).to have_attributes(allergies: nil, has_anaphylaxis_risk: true)
  end

  it "retains meaningful text and rejects nothing to add without explicit clearing" do
    medical = participant_event.create_medical!(medical_conditions: "asthma", has_anaphylaxis_risk: true)

    patch health_path, params: {
      medical: { section_response: "nothing_to_add", medical_conditions: "asthma", has_anaphylaxis_risk: "1" },
      dietary: { section_response: "nothing_to_add" },
      accessibility: { section_response: "nothing_to_add" }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(medical.reload).to have_attributes(medical_conditions: "asthma", has_anaphylaxis_risk: true)
  end

  it "clears only the selected section when explicitly requested" do
    medical = participant_event.create_medical!(medical_conditions: "asthma", has_anaphylaxis_risk: true)
    dietary = participant_event.create_dietary!(intolerances: "lactose")

    patch health_path, params: {
      medical: {
        section_response: "nothing_to_add", clear_details: "1", medical_conditions: "asthma",
        has_anaphylaxis_risk: "1"
      },
      dietary: { section_response: "details", intolerances: "lactose" },
      accessibility: { section_response: "nothing_to_add" }
    }

    expect(response).to have_http_status(:redirect)
    expect(medical.reload).to have_attributes(medical_conditions: nil, has_anaphylaxis_risk: false,
                                               section_response: "nothing_to_add")
    expect(dietary.reload.intolerances).to eq("lactose")
  end
end
