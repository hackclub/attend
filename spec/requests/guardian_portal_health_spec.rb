require "rails_helper"

RSpec.describe "Guardian portal health sections", type: :request do
  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }
  let(:guardian) { create(:guardian) }
  let!(:gpe) { create(:guardian_participant_event, guardian: guardian, participant_event: participant_event) }
  let(:token) { gpe.generate_invite_token! }

  it "uses the same normalization and response persistence as attendee submission" do
    patch guardian_portal_update_step_path(token: token, step: "participant_info"), params: {
      participant: { legal_first_name: "Kid", legal_last_name: "Tester" },
      medical: { section_response: "details", allergies: " Not Applicable ", has_anaphylaxis_risk: "1" },
      dietary: { section_response: "nothing_to_add", diet_type: "" },
      accessibility: { section_response: "private" }
    }

    expect(response).to have_http_status(:redirect)
    expect(participant_event.reload.medical).to have_attributes(allergies: nil, has_anaphylaxis_risk: true,
                                                                 section_response: "details")
    expect(participant_event.dietary.section_response).to eq("nothing_to_add")
    expect(participant_event.accessibility.section_response).to eq("private")
  end

  it "requires explicit clearing when a guardian selects nothing to add over saved details" do
    participant_event.create_medical!(medical_conditions: "asthma")

    patch guardian_portal_update_step_path(token: token, step: "participant_info"), params: {
      participant: { legal_first_name: "Kid", legal_last_name: "Tester" },
      medical: { section_response: "nothing_to_add", medical_conditions: "asthma" },
      dietary: { section_response: "nothing_to_add" },
      accessibility: { section_response: "nothing_to_add" }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(participant_event.medical.reload.medical_conditions).to eq("asthma")
  end
end
