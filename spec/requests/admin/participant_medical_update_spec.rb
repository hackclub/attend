require "rails_helper"

# Staff forms don't ask the "Nothing to add" question, so anything they record
# over a participant's saved "Nothing to add" has to save rather than 422.
RSpec.describe "Admin participant medical update", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }
  let(:admin) { User.create!(email: "medical-admin@example.com", name: "Robin Placeholder", global_role: "global_admin") }

  before do
    participant_event.create_medical!(section_response: :nothing_to_add)
    participant_event.create_dietary!(section_response: :nothing_to_add)
    participant_event.create_accessibility!(section_response: :nothing_to_add)
    sign_in admin
    # Warm-up GET so the first PATCH isn't the one Devise's sign-in tracking hits.
    get medical_admin_event_participant_path(event, participant_event)
  end

  def patch_medical(medical: {}, dietary: {}, accessibility: {})
    patch medical_admin_event_participant_path(event, participant_event), params: {
      medical: { allergies: "", has_anaphylaxis_risk: "0", requires_refrigeration: "0" }.merge(medical),
      dietary: { diet_type: "", cross_contamination_risk: "0" }.merge(dietary),
      accessibility: { uses_wheelchair: "0", has_adhd: "0" }.merge(accessibility)
    }
  end

  it "flags anaphylaxis risk on a participant who answered nothing to add" do
    patch_medical(medical: { has_anaphylaxis_risk: "1" })

    expect(response).to redirect_to(medical_admin_event_participant_path(event, participant_event))
    expect(participant_event.medical.reload).to have_attributes(has_anaphylaxis_risk: true, section_response: "details")
    expect(participant_event.dietary.reload.section_response).to eq("nothing_to_add")
    expect(participant_event.accessibility.reload.section_response).to eq("nothing_to_add")
  end

  it "records a diet on a participant who answered nothing to add" do
    patch_medical(dietary: { diet_type: "vegetarian" })

    expect(response).to redirect_to(medical_admin_event_participant_path(event, participant_event))
    expect(participant_event.dietary.reload).to have_attributes(diet_type: "vegetarian", section_response: "details")
  end

  it "records an accessibility need on a participant who answered nothing to add" do
    patch_medical(accessibility: { uses_wheelchair: "1" })

    expect(response).to redirect_to(medical_admin_event_participant_path(event, participant_event))
    expect(participant_event.accessibility.reload).to have_attributes(uses_wheelchair: true, section_response: "details")
  end

  it "keeps nothing to add when staff save without adding anything" do
    patch_medical

    expect(response).to redirect_to(medical_admin_event_participant_path(event, participant_event))
    expect(participant_event.medical.reload.section_response).to eq("nothing_to_add")
  end
end
