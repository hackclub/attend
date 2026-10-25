require "rails_helper"

RSpec.describe "health section responses" do
  let(:participant_event) { create(:participant_event) }

  it "keeps unanswered, explicit nothing, private, and details distinct" do
    medical = participant_event.build_medical
    expect(medical.effective_section_response).to be_nil

    medical.section_response = :nothing_to_add
    expect(medical).to be_valid
    expect(medical.effective_section_response).to eq("nothing_to_add")

    medical.section_response = :private
    expect(medical).to be_valid
    expect(medical.effective_section_response).to eq("private")

    medical.section_response = :details
    expect(medical).to be_valid
    expect(medical.effective_section_response).to eq("details")
  end

  it "treats legacy disclosures as details without backfilling the response" do
    medical = participant_event.create_medical!(medical_conditions: "asthma", has_anaphylaxis_risk: true)

    expect(medical.section_response).to be_nil
    expect(medical.effective_section_response).to eq("details")
  end

  it "rejects nothing to add while details or flags remain" do
    medical = participant_event.build_medical(medical_conditions: "asthma", section_response: :nothing_to_add)

    expect(medical).not_to be_valid
    expect(medical.errors[:section_response]).to include("cannot be Nothing to add while details are present")
  end

  it "allows private with retained disclosures and leaves sibling flags intact" do
    medical = participant_event.create_medical!(medical_conditions: "asthma", has_anaphylaxis_risk: true)
    medical.update!(section_response: :private)

    expect(medical.reload).to have_attributes(
      section_response: "private",
      medical_conditions: "asthma",
      has_anaphylaxis_risk: true
    )
  end

  it "does not classify a blank section as no needs" do
    dietary = participant_event.create_dietary!(section_response: :details)

    expect(dietary.effective_section_response).to eq("details")
    expect(dietary.health_section_has_details?).to be(false)
  end

  it "preserves surrounding whitespace on meaningful answers" do
    medical = participant_event.create_medical!(allergies: "  No known allergies  ")

    expect(medical.reload.allergies).to eq("  No known allergies  ")
  end
end
